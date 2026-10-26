-- The RS485 port and everything on it, for parkeze-rs485.
--
-- Kept apart from the daemon so the tests can drive it with a fake clock
-- against a simulated slave: everything that touches the bus or decides when
-- is here, and the daemon only supplies the clock, the port path and the
-- loop. See docs/rs485.md.
--
-- Lua, in a ucode tree, because of the Modbus library. libmodbus is the one
-- OpenWrt packages, and its bindings are Lua (lua-libmodbus, 8KB) and Python
-- (python3-libmodbus, which needs python3-light: megabytes a 16MB board does
-- not have). There is no ucode binding, and writing one means compiling a
-- package for every architecture, which this feed does not do. So the framing,
-- CRC, timeouts and flushing are libmodbus's, and this file is scheduling and
-- decoding.
--
-- One process owns the port and asks one question at a time. That is the whole
-- of the serialisation: on a shared bus the watchdog, the battery and anything
-- a site wires to the DC connector are slaves of one master, and two masters
-- on one RS485 pair corrupt each other's frames.

local M = {}

-- ── what ChirpStack's RAK support does, which is the only known-working use
-- of this bus (chirpstack-gateway-utils, src/rak/watchdog.rs and battery.rs):
-- 9600 8N1, slave 0xC8 is the power board's watchdog and is fed by writing 10
-- to register 0x0001, slave 0x6E is the battery. Neither is documented by RAK
-- beyond that code and the support reply quoted in chirpstack-gateway-os#155.
M.WATCHDOG_REGISTER = 0x0001
M.WATCHDOG_VALUE = 10
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
M.INTERNAL_TIMEOUT_MS = 300

M.BATTERY_INTERVAL = 300
-- An optional accessory: most units have no battery and never will. Asking
-- one that has never answered every five minutes is bus time spent on nothing.
M.BATTERY_ABSENT_INTERVAL = 1800

M.PORT_RETRY = 10
M.STATE_EVERY = 60
-- A report is a whole parkeze-claim run, over a SIM on many gateways. A state
-- that flaps is reported at most this often, and its last state still goes.
M.REPORT_GAP = 300

M.DEVICE_INTERVAL = 60
M.DEVICE_TIMEOUT_MS = 500
-- What a report and an MQTT answer (capped at 8KB) can carry.
M.MAX_DEVICES = 8
M.MAX_REGISTERS = 16
M.MAX_READINGS = 64

local TABLES = { holding = true, input = true, coil = true, discrete = true }
local WORDS = { u16 = 1, s16 = 1, u32 = 2, s32 = 2, f32 = 2, u32le = 2, s32le = 2, f32le = 2 }
local BAUDS = { [1200] = true, [2400] = true, [4800] = true, [9600] = true,
                [19200] = true, [38400] = true, [57600] = true, [115200] = true }

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

-- ── configuration ──────────────────────────────────────────────────────────

local function integer(v, lo, hi)
  local n = tonumber(v)
  if not n or n ~= math.floor(n) or n < lo or n > hi then return nil end
  return n
end

local function slave_of(v)
  if v == nil or v == "" then return nil end
  return integer(v, 1, 247)
end

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

-- A register as UCI carries it: name:table:address[:type[:scale[:unit]]].
--
--   list register 'voltage:input:0x0000:u16:0.1:V'
--   list register 'energy:holding:40:u32le::kWh'
--   list register 'door:discrete:2'
--
-- u32/s32/f32 take two registers, high word first; the le forms are low word
-- first, which is how a good half of meters lay them out. A coil or discrete
-- input reads 0 or 1 and takes no type.
function M.parse_register(spec)
  local parts = {}
  for field in (tostring(spec) .. ":"):gmatch("([^:]*):") do parts[#parts + 1] = field end
  local name, tbl, addr, kind, scale, unit = parts[1], parts[2], parts[3], parts[4], parts[5], parts[6]
  if #parts > 6 then return nil, "too many fields" end
  if not name or not name:match("^[A-Za-z0-9_.-]+$") or #name > 24 then
    return nil, "name must be up to 24 letters, digits, '.', '_' or '-'"
  end
  if not TABLES[tbl or ""] then return nil, "table must be holding, input, coil or discrete" end
  local address = integer(addr, 0, 65535)
  if not address then return nil, "address must be 0-65535" end
  local reg = { name = name, table = tbl, address = address }
  if tbl == "coil" or tbl == "discrete" then
    if kind and kind ~= "" and kind ~= "bool" then return nil, "a " .. tbl .. " has no type" end
    reg.type, reg.words = "bool", 1
  else
    reg.type = (kind and kind ~= "") and kind or "u16"
    reg.words = WORDS[reg.type]
    if not reg.words then return nil, "type must be u16, s16, u32, s32, f32, u32le, s32le or f32le" end
    if address + reg.words - 1 > 65535 then return nil, "runs past register 65535" end
  end
  if scale and scale ~= "" then
    reg.scale = tonumber(scale)
    if not reg.scale or reg.scale ~= reg.scale or reg.scale == math.huge or reg.scale == -math.huge then
      return nil, "scale must be a number"
    end
  end
  if unit and unit ~= "" then
    if not unit:match("^[A-Za-z0-9%%/._-]+$") or #unit > 12 then return nil, "unit must be up to 12 plain characters" end
    reg.unit = unit
  end
  return reg
end

local function list(v)
  if v == nil then return {} end
  if type(v) == "table" then return v end
  return { v }
end

-- The bus and its slaves, from the board and UCI's `parkeze` package as
-- libuci-lua's get_all returns it. A device that does not check out is left
-- out and named in `problems`, which is reported: a typo in one meter's
-- register list must never stop the watchdog being fed.
function M.config(board, sections)
  sections = sections or {}
  local problems = {}
  local function problem(msg) problems[#problems + 1] = msg end

  local bus = sections.rs485 or {}
  local cfg = {
    usb = board.PARKEZE_RS485 or "",
    id = board.PARKEZE_RS485_ID or "",
    baud = 9600, parity = "N", stopbits = 1,
    devices = {},
    problems = problems,
  }
  if bus.baud and bus.baud ~= "" then
    local b = integer(bus.baud, 1, 1000000)
    if b and BAUDS[b] then cfg.baud = b else problem("baud " .. tostring(bus.baud) .. " is not a standard rate; using 9600") end
  end
  if bus.parity and bus.parity ~= "" then
    local p = tostring(bus.parity):upper():sub(1, 1)
    if p == "N" or p == "E" or p == "O" then cfg.parity = p else problem("parity must be none, even or odd; using none") end
  end
  if bus.stopbits and bus.stopbits ~= "" then
    local s = integer(bus.stopbits, 1, 2)
    if s then cfg.stopbits = s else problem("stopbits must be 1 or 2; using 1") end
  end

  local reserved = {}
  local wd = slave_of(board.PARKEZE_RS485_WATCHDOG)
  if wd then
    cfg.watchdog = { slave = wd }
    reserved[wd] = "the watchdog"
  end
  local bat = slave_of(board.PARKEZE_RS485_BATTERY)
  if bat then
    cfg.battery = { slave = bat }
    reserved[bat] = "the battery"
  end

  local ordered = {}
  for _, s in pairs(sections) do
    if type(s) == "table" and s[".type"] == "modbus" then ordered[#ordered + 1] = s end
  end
  table.sort(ordered, function(a, b) return (a[".index"] or 0) < (b[".index"] or 0) end)

  local names, slaves, readings = {}, {}, 0
  for _, s in ipairs(ordered) do
    local name = s.name or s[".name"]
    local label = "device " .. tostring(name)
    local slave = slave_of(s.slave)
    if type(name) ~= "string" or not name:match("^[A-Za-z0-9_.-]+$") or #name > 24 then
      problem("a device needs a name of up to 24 letters, digits, '.', '_' or '-'")
    elseif names[name] then
      problem(label .. " is named twice")
    elseif s.enabled == "0" then
      -- Off: kept in UCI, not polled, not a problem.
    elseif not slave then
      problem(label .. ": slave must be 1-247")
    elseif reserved[slave] then
      problem(label .. ": slave " .. slave .. " is " .. reserved[slave])
    elseif #cfg.devices >= M.MAX_DEVICES then
      problem(label .. ": at most " .. M.MAX_DEVICES .. " devices")
    else
      names[name] = true
      local dev = {
        name = name, slave = slave,
        interval = M.DEVICE_INTERVAL, timeout = M.DEVICE_TIMEOUT_MS,
        registers = {},
      }
      if s.interval and s.interval ~= "" then
        dev.interval = integer(s.interval, 5, 86400)
        if not dev.interval then problem(label .. ": interval must be 5-86400 seconds; using 60"); dev.interval = M.DEVICE_INTERVAL end
      end
      if s.timeout and s.timeout ~= "" then
        dev.timeout = integer(s.timeout, 50, 5000)
        if not dev.timeout then problem(label .. ": timeout must be 50-5000 ms; using 500"); dev.timeout = M.DEVICE_TIMEOUT_MS end
      end
      local seen = {}
      for _, spec in ipairs(list(s.register)) do
        local reg, why = M.parse_register(spec)
        if not reg then
          problem(label .. ": register '" .. tostring(spec) .. "': " .. why)
        elseif seen[reg.name] then
          problem(label .. ": register " .. reg.name .. " is named twice")
        elseif #dev.registers >= M.MAX_REGISTERS then
          problem(label .. ": at most " .. M.MAX_REGISTERS .. " registers")
        elseif readings >= M.MAX_READINGS then
          problem(label .. ": at most " .. M.MAX_READINGS .. " registers in all")
        else
          seen[reg.name] = true
          readings = readings + 1
          dev.registers[#dev.registers + 1] = reg
        end
      end
      if #dev.registers == 0 then
        problem(label .. ": no registers to read")
      else
        if slaves[slave] then problem(label .. ": slave " .. slave .. " is also " .. slaves[slave]) end
        slaves[slave] = name
        cfg.devices[#cfg.devices + 1] = dev
      end
    end
  end
  return cfg
end

-- ── the port ───────────────────────────────────────────────────────────────

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
-- modem's AT port.
function M.resolve(usb, id, sysfs)
  sysfs = sysfs or "/sys/bus/usb/devices"
  if not usb or not usb:match("^%d+%-[%d.]+$") then return nil, "no RS485 port on this board" end
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
function M.new(cfg, deps)
  local self = setmetatable({}, Service)
  self.cfg, self.mb = cfg, deps.modbus
  self.clock = deps.clock
  self.resolve = deps.resolve
  self.present = deps.present
  self.on_report = deps.report
  self.logf = deps.log or function() end
  local now = self.clock()
  self.port = { state = "closed", due = now }
  if cfg.watchdog then
    self.watchdog = { slave = cfg.watchdog.slave, state = "starting", failures = 0, due = now }
  end
  if cfg.battery then
    self.battery = { slave = cfg.battery.slave, state = "starting", due = now }
  end
  self.devices = {}
  for i, d in ipairs(cfg.devices) do
    self.devices[i] = { cfg = d, state = "starting", due = now }
  end
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
    self:log("warning", "RS485 port " .. tostring(self.port.device) .. " went away")
    self:close()
    self.port.state, self.port.due = "closed", now
  end
  if now < self.port.due then return nil, self.port.error or "RS485 port not open" end

  local path, why = self.resolve()
  if not path then
    if self.port.state ~= "absent" or self.port.error ~= why then
      self:log("warning", "RS485 port: " .. why)
    end
    self.port = { state = "absent", error = why, due = now + M.PORT_RETRY }
    return nil, why
  end
  local mb = self.mb
  local ctx = mb.new_rtu(path, self.cfg.baud, self.cfg.parity, 8, self.cfg.stopbits)
  -- Recover from a bad frame by flushing and waiting out the response timeout,
  -- which is also the line's silence between frames that RTU needs. Without it
  -- a half-received reply is read as the start of the next one.
  ctx:set_error_recovery(mb.ERROR_RECOVERY_PROTOCOL)
  local ok, err = ctx:connect()
  if not ok then
    pcall(function() ctx:close() end)
    self:log("warning", "RS485 port " .. path .. ": " .. tostring(err))
    self.port = { state = "error", device = path, error = tostring(err), due = now + M.PORT_RETRY }
    return nil, tostring(err)
  end
  self.ctx = ctx
  self.port = { state = "open", device = path, due = now }
  self:log("info", string.format("RS485 port %s open at %d %s%d", path, self.cfg.baud, self.cfg.parity, self.cfg.stopbits))
  return ctx
end

-- One request to one slave: ok, result or nil, kind, error. kind is
-- "unanswered", "error" (the slave answered badly) or "port".
function Service:ask(slave, timeout_ms, fn)
  local ctx, why = self:bus()
  if not ctx then return nil, "port", why end
  ctx:set_slave(slave)
  ctx:set_response_timeout(math.floor(timeout_ms / 1000), (timeout_ms % 1000) * 1000)
  local result, err = fn(ctx)
  if result ~= nil then return true, result end
  local kind = M.classify(err)
  if kind == "port" then
    self:log("warning", "RS485 port " .. tostring(self.port.device) .. ": " .. tostring(err) .. "; reopening")
    self:close()
    self.port = { state = "error", device = self.port.device, error = tostring(err), due = self.clock() + M.PORT_RETRY }
  end
  return nil, kind, tostring(err)
end

local function read_block(ctx, tbl, address, count)
  if tbl == "holding" then return ctx:read_registers(address, count) end
  if tbl == "input" then return ctx:read_input_registers(address, count) end
  if tbl == "coil" then return ctx:read_bits(address, count) end
  return ctx:read_input_bits(address, count)
end

-- A voltage of 1280 × 0.01 is 12.8, not 12.800000000000001: ten significant
-- figures drop the binary noise a scale adds. Not fewer, because an energy
-- counter in a u32 has ten digits of its own and every one is real.
local function tidy(v, digits)
  return tonumber(string.format("%." .. (digits or 10) .. "g", v))
end

-- Raw registers to a number. Integers are put together here rather than with
-- lua-libmodbus's get_s16/get_s32, which convert through C casts that are
-- undefined for values past their range; a float needs the bit pattern, which
-- only C can reinterpret, so that is the library's.
function M.decode(mb, reg, words)
  local hi, lo = words[1], words[2]
  local t = reg.type
  local v
  if t == "bool" or t == "u16" then v = hi
  elseif t == "s16" then v = hi >= 0x8000 and hi - 0x10000 or hi
  elseif t == "u32" then v = hi * 65536 + lo
  elseif t == "u32le" then v = lo * 65536 + hi
  elseif t == "s32" or t == "s32le" then
    if t == "s32le" then hi, lo = lo, hi end
    v = hi * 65536 + lo
    if v >= 0x80000000 then v = v - 0x100000000 end
  elseif t == "f32" then v = mb.get_f32(hi, lo)
  elseif t == "f32le" then v = mb.get_f32le(hi, lo)
  end
  if v ~= v or v == math.huge or v == -math.huge then return nil, "not a number" end
  -- A float has seven significant digits; the rest of its double is noise
  -- (0.1 reads as 0.100000001490116).
  if t == "f32" or t == "f32le" then v = tidy(v, 7) end
  if reg.scale then v = tidy(v * reg.scale) end
  return v
end

function Service:feed()
  local wd, now = self.watchdog, self.clock()
  local ok, kind, err = self:ask(wd.slave, M.INTERNAL_TIMEOUT_MS, function(ctx)
    return ctx:write_register(M.WATCHDOG_REGISTER, M.WATCHDOG_VALUE)
  end)
  now = self.clock()
  if ok then
    if wd.state ~= "fed" then self:log("info", "watchdog at slave " .. wd.slave .. " fed") end
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
  -- and what a newer one may look like on PoE: the bench Pro (2026-10-26, on
  -- PoE) answered nothing at 0xC8, read or write, and nobody knows which it
  -- is. So silence is not a fault and is not treated as one: logged once,
  -- asked again at the ordinary interval, which still fits four tries inside
  -- the ten minutes a newer board on DC would allow. A port that is not there
  -- yet is different: nothing was asked, the CH340 driver loads seconds into
  -- boot, and the first feed should follow it rather than wait two minutes.
  if wd.answered then
    if wd.state ~= "failing" or wd.failures % 20 == 0 then
      self:log("err", string.format("watchdog at slave %d not fed (%s, %d in a row): %s",
        wd.slave, kind, wd.failures, err))
    end
    wd.state, wd.due = "failing", now + M.WATCHDOG_RETRY
  else
    if wd.state ~= "absent" then
      self:log("info", string.format("no watchdog answers at slave %d (%s); feeding it anyway", wd.slave, err))
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
    local ok, res, e = self:ask(bat.slave, M.INTERNAL_TIMEOUT_MS, function(ctx)
      return ctx:read_registers(r[2], 1)
    end)
    if not ok then kind, err = res, e; break end
    values[r[1]] = res[1]
  end
  local now = self.clock()
  if not kind then
    bat.state, bat.error, bat.answered, bat.readAt = "ok", nil, true, now
    bat.voltage = tidy(values.voltage * 0.01)
    bat.healthPercent = values.health
    bat.remaining, bat.fullCharge = values.remaining, values.full
    bat.remainingPercent = values.full > 0
      and math.floor(values.remaining / values.full * 10000 + 0.5) / 100 or nil
    bat.due = now + M.BATTERY_INTERVAL
    return
  end
  bat.error = err
  if kind == "unanswered" and not bat.answered then
    if bat.state ~= "absent" then self:log("info", "no battery answers at slave " .. bat.slave) end
    bat.state, bat.due = "absent", now + M.BATTERY_ABSENT_INTERVAL
  else
    if bat.state ~= kind then self:log("warning", "battery at slave " .. bat.slave .. ": " .. err) end
    bat.state = kind == "port" and "unanswered" or kind
    bat.due = now + (kind == "port" and M.PORT_RETRY or M.BATTERY_INTERVAL)
  end
end

function Service:read_device(dev)
  local d = dev.cfg
  local readings, read, first_kind, first_err = {}, 0, nil, nil
  local skip
  for i, reg in ipairs(d.registers) do
    local reading = { name = reg.name, unit = reg.unit }
    if skip then
      reading.error = skip
    else
      local ok, res, err = self:ask(d.slave, d.timeout, function(ctx)
        return read_block(ctx, reg.table, reg.address, reg.words)
      end)
      if ok then
        local v, why = M.decode(self.mb, reg, res)
        reading.value, reading.error = v, why
        if v then read = read + 1 else first_kind, first_err = first_kind or "error", first_err or why end
      else
        reading.error = err
        first_kind, first_err = first_kind or res, first_err or err
        -- A slave that does not answer will not answer the next register
        -- either, and each one costs a whole timeout of bus time the watchdog
        -- may be waiting for. An exception is about that register alone.
        if res ~= "error" then skip = err end
      end
    end
    readings[i] = reading
  end
  local now = self.clock()
  local state
  if read == #d.registers then state = "ok"
  elseif read > 0 then state = "partial"
  elseif first_kind == "error" then state = "error"
  else state = "unanswered" end
  if state ~= dev.state then
    if state == "ok" then
      self:log("info", "device " .. d.name .. " at slave " .. d.slave .. " reads")
    else
      self:log("warning", "device " .. d.name .. " at slave " .. d.slave .. " is " .. state .. ": " .. tostring(first_err or "a value is not a number"))
    end
  end
  dev.state, dev.error = state, first_err
  -- Last good values are kept with their time; a reading that failed this
  -- time says so instead of showing a stale number as current.
  dev.readings = readings
  if state ~= "unanswered" and state ~= "error" then dev.readAt = now end
  dev.attemptAt = now
  dev.due = now + (first_kind == "port" and M.PORT_RETRY or d.interval)
end

-- How the bus is, in the words that warrant telling parkeze.net now rather
-- than at the next six-hourly report. Values that drift are not in it; a
-- battery crossing a band is.
function Service:summary()
  local parts = { "port=" .. self.port.state }
  if self.watchdog then parts[#parts + 1] = "watchdog=" .. self.watchdog.state end
  if self.battery then
    local band = ""
    local p = self.battery.remainingPercent
    if self.battery.state == "ok" and p then
      band = p <= 10 and "/10" or p <= 20 and "/20" or p <= 50 and "/50" or "/full"
    end
    parts[#parts + 1] = "battery=" .. self.battery.state .. band
  end
  for _, dev in ipairs(self.devices) do parts[#parts + 1] = dev.cfg.name .. "=" .. dev.state end
  return table.concat(parts, " ")
end

local function settled(self)
  if self.watchdog and self.watchdog.state == "starting" then return false end
  if self.battery and self.battery.state == "starting" then return false end
  for _, dev in ipairs(self.devices) do if dev.state == "starting" then return false end end
  return true
end

function Service:maybe_report()
  if not settled(self) then return end
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

-- Run whatever is due, most urgent first, and return how long until the next
-- thing is. The watchdog is checked again after every other job, so a slow
-- device can delay a feed by one device's poll and never by more.
function Service:tick()
  local ran = false
  for _ = 1, 64 do
    local now, job = self.clock(), nil
    if self.watchdog and self.watchdog.due <= now then
      job = function() self:feed() end
    elseif self.battery and self.battery.due <= now then
      job = function() self:read_battery() end
    else
      local soonest
      for _, dev in ipairs(self.devices) do
        if dev.due <= now and (not soonest or dev.due < soonest.due) then soonest = dev end
      end
      if soonest then job = function() self:read_device(soonest) end end
    end
    if not job then break end
    job()
    ran = true
  end
  self:maybe_report()
  local now, next_due = self.clock(), math.huge
  if self.watchdog then next_due = math.min(next_due, self.watchdog.due) end
  if self.battery then next_due = math.min(next_due, self.battery.due) end
  for _, dev in ipairs(self.devices) do next_due = math.min(next_due, dev.due) end
  if self.report.pending and self.report.last then next_due = math.min(next_due, self.report.last + M.REPORT_GAP) end
  if next_due == math.huge then next_due = now + M.WATCHDOG_INTERVAL end
  return math.max(1, next_due - now), ran
end

-- The state as the daemon records it: times are monotonic seconds, turned
-- into ages by M.view when somebody asks.
function Service:state()
  local s = { at = self.clock(), port = { state = self.port.state, device = self.port.device, error = self.port.error } }
  s.port.usb = self.cfg.usb ~= "" and self.cfg.usb or nil
  s.bus = { baud = self.cfg.baud, parity = self.cfg.parity, stopbits = self.cfg.stopbits }
  if self.watchdog then
    local w = self.watchdog
    s.watchdog = { slave = w.slave, state = w.state, fedAt = w.fedAt, failures = w.failures, error = w.error }
  end
  if self.battery then
    local b = self.battery
    s.battery = { slave = b.slave, state = b.state, readAt = b.readAt, error = b.error, voltage = b.voltage,
                  healthPercent = b.healthPercent, remaining = b.remaining, fullCharge = b.fullCharge,
                  remainingPercent = b.remainingPercent }
  end
  if #self.devices > 0 then
    s.devices = {}
    for i, dev in ipairs(self.devices) do
      s.devices[i] = { name = dev.cfg.name, slave = dev.cfg.slave, state = dev.state, error = dev.error,
                       readAt = dev.readAt, readings = dev.readings }
    end
  end
  if #self.cfg.problems > 0 then s.problems = self.cfg.problems end
  return s
end

local function ago(stamp, now)
  if not stamp then return nil end
  return math.max(0, math.floor(now - stamp + 0.5))
end

-- What `parkeze-rs485 status` prints, and what goes to parkeze.net: the
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
              port = state.port, bus = state.bus, problems = state.problems }
  if state.watchdog then
    local w = state.watchdog
    v.watchdog = { slave = w.slave, state = w.state, fedAgo = ago(w.fedAt, now), failures = w.failures, error = w.error }
  end
  if state.battery then
    local b = state.battery
    v.battery = { slave = b.slave, state = b.state, readAgo = ago(b.readAt, now), error = b.error,
                  voltage = b.voltage, healthPercent = b.healthPercent, remaining = b.remaining,
                  fullCharge = b.fullCharge, remainingPercent = b.remainingPercent }
  end
  if state.devices then
    v.devices = {}
    for i, d in ipairs(state.devices) do
      v.devices[i] = { name = d.name, slave = d.slave, state = d.state, error = d.error,
                       readAgo = ago(d.readAt, now), readings = d.readings }
    end
  end
  return v
end

return M
