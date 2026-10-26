-- The RAK7289CV2's power board, for parkeze-rak-power: its hardware watchdog
-- and the optional RAK battery pack, both Modbus RTU slaves on the CH340
-- inside the Pro.
--
-- RAK-specific on purpose, and small on purpose. This is not a general RS485
-- or Modbus service: the slaves, the registers and the line settings are
-- RAK's and fixed, and nothing here is configurable. A gateway with real IO
-- gets its own design rather than growing this one.
--
-- Kept apart from the daemon so the tests can drive it with a fake clock
-- against a simulated slave: everything that touches the bus or decides when
-- is here, and the daemon only supplies the clock, the port path and the
-- loop. See docs/rak-power.md.
--
-- Lua, in a ucode tree, because of the Modbus library. libmodbus is the one
-- OpenWrt packages, and its bindings are Lua (lua-libmodbus, 8KB) and Python
-- (python3-libmodbus, which needs python3-light: megabytes a 16MB board does
-- not have). There is no ucode binding, and writing one means compiling a
-- package for every architecture, which this feed does not do. So the framing,
-- CRC, timeouts and flushing are libmodbus's.
--
-- One process owns the port and asks one question at a time: the watchdog and
-- the battery are slaves of one master, and a second master on the line
-- corrupts both.

local M = {}

-- What ChirpStack's RAK support does, which is the only known-working use of
-- this bus (chirpstack-gateway-utils, src/rak/watchdog.rs and battery.rs):
-- 9600 8N1, slave 0xC8 is the power board's watchdog and is fed by writing 10
-- to register 0x0001, slave 0x6E is the battery. Neither is documented by RAK
-- beyond that code and the support reply quoted in chirpstack-gateway-os#155.
M.BAUD = 9600
M.WATCHDOG = 0xC8
M.WATCHDOG_REGISTER = 0x0001
M.WATCHDOG_VALUE = 10
M.BATTERY = 0x6E
M.BATTERY_VOLTAGE = 0x6000          -- ×0.01 V
M.BATTERY_HEALTH = 0x6003           -- percent
M.BATTERY_REMAINING = 0x6005        -- same unit as full charge
M.BATTERY_FULL = 0x6006

-- The watchdog cuts power ten minutes after its last feed (RAK, in #155), and
-- the unit in that issue stayed off until somebody power-cycled it. ChirpStack
-- feeds every five minutes from cron, which survives exactly one missed feed.
-- Every two, and every fifteen seconds once a feed has failed, buys four
-- misses of margin for a write that costs about 20ms of bus time.
M.WATCHDOG_INTERVAL = 120
M.WATCHDOG_RETRY = 15
-- ChirpStack waits 100ms. The CH340 is a full-speed USB device behind a hub,
-- and a reply at 9600 baud is 8ms on the wire before USB latency, so 100ms is
-- tight for a write that must not be lost to a slow poll; a timeout costs
-- nothing but the wait.
M.TIMEOUT_MS = 300

M.BATTERY_INTERVAL = 300
-- An optional accessory: most units have no battery pack and never will.
-- Asking one that has never answered every five minutes is bus time spent on
-- nothing.
M.BATTERY_ABSENT_INTERVAL = 1800

M.PORT_RETRY = 10
M.STATE_EVERY = 60
-- A report is a whole parkeze-claim run, over a SIM on many gateways. A state
-- that flaps is reported at most this often, and its last state still goes.
M.REPORT_GAP = 300

-- What libmodbus says when a slave answered with something other than what
-- was asked: an exception, or a frame that did not check out. Anything else
-- that is not a timeout is the port itself — a USB device that went away
-- leaves a descriptor that fails every call with EIO — and is reopened.
local ANSWERED = {
  ["Illegal function"] = true, ["Illegal data address"] = true,
  ["Illegal data value"] = true, ["Slave device or server failure"] = true,
  ["Acknowledge"] = true, ["Slave device or server is busy"] = true,
  ["Negative acknowledge"] = true, ["Memory parity error"] = true,
  ["Gateway path unavailable"] = true, ["Target device failed to respond"] = true,
  ["Invalid CRC"] = true, ["Invalid data"] = true, ["Invalid exception code"] = true,
  ["Too many data"] = true, ["Response not from requested slave"] = true,
}

function M.classify(err)
  err = tostring(err or "")
  -- Linux says "Connection timed out", macOS "Operation timed out".
  if err:find("timed out", 1, true) then return "unanswered" end
  if ANSWERED[err] then return "error" end
  return "port"
end

-- ── the port ───────────────────────────────────────────────────────────────

-- /etc/parkeze/board.conf is KEY='value' lines written by build.sh.
function M.read_board(path)
  local board = {}
  local f = io.open(path or "/etc/parkeze/board.conf", "r")
  if not f then return board end
  for line in f:lines() do
    local k, v = line:match("^([A-Z0-9_]+)='(.*)'$")
    if k then board[k] = v end
  end
  f:close()
  return board
end

local function read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local v = f:read("*l")
  f:close()
  return v
end

-- Which ttyUSB the bridge at a USB port is, if it is there and is the part
-- the board says. By path, never by number: on a RAK7289CV2 the EG95 modem
-- takes four ttyUSB nodes and which driver binds first decides who is
-- ttyUSB0 — ChirpStack opens /dev/ttyUSB0, which on that board can be the
-- modem's AT port. On the bench Pro it was ttyUSB4.
function M.resolve(usb, id, sysfs)
  sysfs = sysfs or "/sys/bus/usb/devices"
  if not usb or not usb:match("^%d+%-[%d.]+$") then return nil, "no RAK power board on this board" end
  local dev = sysfs .. "/" .. usb
  local vid, pid = read_file(dev .. "/idVendor"), read_file(dev .. "/idProduct")
  if not vid then return nil, "nothing at USB " .. usb end
  if id and id ~= "" and (vid .. ":" .. pid) ~= id then
    return nil, "USB " .. usb .. " is " .. vid .. ":" .. pid .. ", not " .. id
  end
  local ls = io.popen("ls -d " .. dev .. "/" .. usb .. ":1.0/ttyUSB* 2>/dev/null")
  local found = ls and ls:read("*l")
  if ls then ls:close() end
  local tty = found and found:match("(ttyUSB%d+)$")
  if not tty then return nil, "USB " .. usb .. " has no serial driver bound" end
  return "/dev/" .. tty
end

-- Whether a port resolve() found is still that bridge's tty: asked before
-- every request, so it is one open() of a sysfs file and no fork.
function M.present(usb, path, sysfs)
  sysfs = sysfs or "/sys/bus/usb/devices"
  local tty = path and path:match("^/dev/(ttyUSB%d+)$")
  if not tty then return false end
  local f = io.open(sysfs .. "/" .. usb .. "/" .. usb .. ":1.0/" .. tty .. "/tty/" .. tty .. "/dev", "r")
  if not f then return false end
  f:close()
  return true
end

-- ── the service ────────────────────────────────────────────────────────────

local Service = {}
Service.__index = Service

-- deps:
--   modbus    the lua-libmodbus module
--   clock     seconds, monotonic (the daemon reads /proc/uptime)
--   resolve   function() -> device path, or nil and why
--   present   function(path) -> whether that path is still the port
--   report    function() asking parkeze.net to be told; may be nil
--   log       function(level, message); may be nil
function M.new(deps)
  local self = setmetatable({}, Service)
  self.mb = deps.modbus
  self.clock = deps.clock
  self.resolve = deps.resolve
  self.present = deps.present
  self.on_report = deps.report
  self.logf = deps.log or function() end
  local now = self.clock()
  self.port = { state = "closed", due = now }
  self.watchdog = { state = "starting", failures = 0, due = now }
  self.battery = { state = "starting", due = now }
  self.report = { last = nil, pending = false }
  return self
end

function Service:log(level, msg) self.logf(level, msg) end

function Service:close()
  if self.ctx then pcall(function() self.ctx:close() end) end
  self.ctx = nil
end

-- The port, open, or nil and why. Retried every PORT_RETRY seconds while it is
-- missing, so a bridge that enumerates after this starts — the CH340 driver
-- loads late in boot — is picked up without a restart.
function Service:bus()
  local now = self.clock()
  if self.ctx then
    -- Still there? A USB reset renumbers the tty, and a descriptor on the old
    -- node is dead without saying so until the next call times out.
    if self.present(self.port.device) then return self.ctx end
    self:log("warning", "power board port " .. tostring(self.port.device) .. " went away")
    self:close()
    self.port.state, self.port.due = "closed", now
  end
  if now < self.port.due then return nil, self.port.error or "power board port not open" end

  local path, why = self.resolve()
  if not path then
    if self.port.state ~= "absent" or self.port.error ~= why then
      self:log("warning", "power board port: " .. why)
    end
    self.port = { state = "absent", error = why, due = now + M.PORT_RETRY }
    return nil, why
  end
  local mb = self.mb
  local ctx = mb.new_rtu(path, M.BAUD, "N", 8, 1)
  -- Recover from a bad frame by flushing and waiting out the response timeout,
  -- which is also the line's silence between frames that RTU needs. Without it
  -- a half-received reply is read as the start of the next one.
  ctx:set_error_recovery(mb.ERROR_RECOVERY_PROTOCOL)
  local ok, err = ctx:connect()
  if not ok then
    pcall(function() ctx:close() end)
    self:log("warning", "power board port " .. path .. ": " .. tostring(err))
    self.port = { state = "error", device = path, error = tostring(err), due = now + M.PORT_RETRY }
    return nil, tostring(err)
  end
  self.ctx = ctx
  self.port = { state = "open", device = path, due = now }
  self:log("info", "power board port " .. path .. " open")
  return ctx
end

-- One request to one slave: ok, result or nil, kind, error. kind is
-- "unanswered", "error" (the slave answered badly) or "port".
function Service:ask(slave, fn)
  local ctx, why = self:bus()
  if not ctx then return nil, "port", why end
  ctx:set_slave(slave)
  ctx:set_response_timeout(0, M.TIMEOUT_MS * 1000)
  local result, err = fn(ctx)
  if result ~= nil then return true, result end
  local kind = M.classify(err)
  if kind == "port" then
    self:log("warning", "power board port " .. tostring(self.port.device) .. ": " .. tostring(err) .. "; reopening")
    self:close()
    self.port = { state = "error", device = self.port.device, error = tostring(err), due = self.clock() + M.PORT_RETRY }
  end
  return nil, kind, tostring(err)
end

function Service:feed()
  local wd = self.watchdog
  local ok, kind, err = self:ask(M.WATCHDOG, function(ctx)
    return ctx:write_register(M.WATCHDOG_REGISTER, M.WATCHDOG_VALUE)
  end)
  local now = self.clock()
  if ok then
    if wd.state ~= "fed" then self:log("info", "watchdog fed") end
    wd.state, wd.fedAt, wd.failures, wd.error, wd.answered = "fed", now, 0, nil, true
    wd.due = now + M.WATCHDOG_INTERVAL
    return
  end
  wd.failures = wd.failures + 1
  wd.error = err
  -- Fed before, this boot, and now not: the unit is on a clock that ends in a
  -- power cut, so it is retried hard and logged loudly.
  --
  -- Never fed is what an older revision, which has no watchdog, looks like,
  -- and also what a newer one looks like on PoE: the bench Pro's factory
  -- descriptor lists `hwwdg`, and on PoE (2026-10-26) it answered nothing at
  -- 0xC8, read or write. So silence is not a fault and is not treated as one:
  -- logged once, asked again at the ordinary interval, which still fits four
  -- tries inside the ten minutes a board on DC would allow. A port that is not there
  -- yet is different: nothing was asked, the CH340 driver loads seconds into
  -- boot, and the first feed should follow it rather than wait two minutes.
  if wd.answered then
    if wd.state ~= "failing" or wd.failures % 20 == 0 then
      self:log("err", string.format("watchdog not fed (%s, %d in a row): %s", kind, wd.failures, err))
    end
    wd.state, wd.due = "failing", now + M.WATCHDOG_RETRY
  else
    if wd.state ~= "absent" then
      self:log("info", "no watchdog answers (" .. err .. "); feeding it anyway")
    end
    wd.state = "absent"
    wd.due = now + (kind == "port" and M.PORT_RETRY or M.WATCHDOG_INTERVAL)
  end
end

function Service:read_battery()
  local bat = self.battery
  local values, kind, err = {}, nil, nil
  -- One register at a time, as ChirpStack reads them. 0x6000-0x6006 is one
  -- block, but nothing says the battery answers a read across the registers
  -- between the four that are known.
  for _, r in ipairs({ { "voltage", M.BATTERY_VOLTAGE }, { "health", M.BATTERY_HEALTH },
                       { "remaining", M.BATTERY_REMAINING }, { "full", M.BATTERY_FULL } }) do
    local ok, res, e = self:ask(M.BATTERY, function(ctx)
      return ctx:read_registers(r[2], 1)
    end)
    if not ok then kind, err = res, e; break end
    values[r[1]] = res[1]
  end
  local now = self.clock()
  if not kind then
    if bat.state ~= "ok" then self:log("info", "battery pack answers") end
    bat.state, bat.error, bat.answered, bat.readAt = "ok", nil, true, now
    -- 1280 × 0.01 is 12.800000000000001 in a double.
    bat.voltage = math.floor(values.voltage + 0.5) / 100
    bat.healthPercent = values.health
    bat.remaining, bat.fullCharge = values.remaining, values.full
    bat.remainingPercent = values.full > 0
      and math.floor(values.remaining / values.full * 10000 + 0.5) / 100 or nil
    bat.due = now + M.BATTERY_INTERVAL
    return
  end
  bat.error = err
  if not bat.answered then
    if bat.state ~= "absent" then self:log("info", "no battery pack answers") end
    bat.state = "absent"
    bat.due = now + (kind == "port" and M.PORT_RETRY or M.BATTERY_ABSENT_INTERVAL)
  else
    if bat.state ~= kind then self:log("warning", "battery pack: " .. err) end
    bat.state = kind == "port" and "unanswered" or kind
    bat.due = now + (kind == "port" and M.PORT_RETRY or M.BATTERY_INTERVAL)
  end
end

-- How the power board is, in the words that warrant telling parkeze.net now
-- rather than at the next six-hourly report. A voltage drifts and is not in
-- it; the charge crossing a band is.
function Service:summary()
  local band = ""
  local p = self.battery.remainingPercent
  if self.battery.state == "ok" and p then
    band = p <= 10 and "/10" or p <= 20 and "/20" or p <= 50 and "/50" or "/full"
  end
  return "port=" .. self.port.state .. " watchdog=" .. self.watchdog.state
    .. " battery=" .. self.battery.state .. band
end

function Service:maybe_report()
  if self.watchdog.state == "starting" or self.battery.state == "starting" then return end
  local now, s = self.clock(), self:summary()
  -- The first settled state is what the report loop's own first report, half
  -- a minute after boot, already carries.
  if not self.baseline then self.baseline = s; return end
  if s ~= self.baseline then
    self.baseline = s
    self.report.pending = true
  end
  if self.report.pending and (not self.report.last or now - self.report.last >= M.REPORT_GAP) then
    self.report.pending, self.report.last = false, now
    self:log("info", "reporting: " .. s)
    if self.on_report then self.on_report() end
  end
end

-- Run whatever is due, the watchdog first, and return how long until the next
-- thing is.
function Service:tick()
  for _ = 1, 8 do
    local now = self.clock()
    if self.watchdog.due <= now then self:feed()
    elseif self.battery.due <= now then self:read_battery()
    else break end
  end
  self:maybe_report()
  local now = self.clock()
  local next_due = math.min(self.watchdog.due, self.battery.due)
  if self.report.pending and self.report.last then next_due = math.min(next_due, self.report.last + M.REPORT_GAP) end
  return math.max(1, next_due - now)
end

-- The state as the daemon records it: times are monotonic seconds, turned
-- into ages by M.view when somebody asks.
function Service:state()
  local w, b = self.watchdog, self.battery
  return {
    at = self.clock(),
    port = { state = self.port.state, device = self.port.device, error = self.port.error },
    watchdog = { state = w.state, fedAt = w.fedAt, failures = w.failures, error = w.error },
    battery = { state = b.state, readAt = b.readAt, error = b.error, voltage = b.voltage,
                healthPercent = b.healthPercent, remaining = b.remaining, fullCharge = b.fullCharge,
                remainingPercent = b.remainingPercent },
  }
end

local function ago(stamp, now)
  if not stamp then return nil end
  return math.max(0, math.floor(now - stamp + 0.5))
end

-- What `parkeze-rak-power status` prints, and what goes to parkeze.net: the
-- recorded state with every time as seconds before now. Ages rather than
-- clock times because a gateway's clock is 1970 until NTP answers, and the
-- watchdog is fed from the first seconds of boot; parkeze.net turns them back
-- into times against its own clock.
--
-- The daemon writes its record at least every STATE_EVERY seconds, so one
-- three times older than that is a daemon that is not running, whatever the
-- record says.
function M.view(state, now)
  if type(state) ~= "table" or not state.at then return { running = false } end
  local v = { running = now - state.at <= 3 * M.STATE_EVERY, updatedAgo = ago(state.at, now),
              port = state.port }
  local w = state.watchdog
  if w then
    v.watchdog = { state = w.state, fedAgo = ago(w.fedAt, now), failures = w.failures, error = w.error }
  end
  local b = state.battery
  if b then
    v.battery = { state = b.state, readAgo = ago(b.readAt, now), error = b.error,
                  voltage = b.voltage, healthPercent = b.healthPercent, remaining = b.remaining,
                  fullCharge = b.fullCharge, remainingPercent = b.remainingPercent }
  end
  return v
end

return M
