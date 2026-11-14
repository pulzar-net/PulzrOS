-- pulzr-rak-power's tests. Run by scripts/test-rak-power.sh, which sets
-- package.path to the feed and, for the simulated bus, package.cpath to a
-- lua-libmodbus built from the release OpenWrt ships.
--
--   unit   the scheduling and the battery arithmetic, against a fake bus
--          whose every answer and every second is chosen here
--   sim    the same service through real libmodbus to a pymodbus power
--          board on a pty pair (RAK_POWER_SIM=<simulator dir>)

local power = require("pulzr.rak_power")

local passed, failed = 0, 0
local function check(what, ok, detail)
  if ok then passed = passed + 1
  else failed = failed + 1; print("FAIL: " .. what .. (detail and (" (" .. tostring(detail) .. ")") or "")) end
end
local function eq(what, got, want) check(what, got == want, "got " .. tostring(got) .. ", want " .. tostring(want)) end

-- ── a bus whose answers and time are ours ──────────────────────────────────

local function fake_bus()
  local bus = { t = 1000, calls = {}, slaves = {}, port = "/dev/ttyUSB4", opens = 0, reports = 0, log = {} }
  function bus.clock() return bus.t end
  local mb = { ERROR_RECOVERY_PROTOCOL = 4 }
  function mb.new_rtu(path, baud, parity, data, stop)
    bus.opened_with = { path, baud, parity, data, stop }
    local ctx = { timeout = 0.5 }
    function ctx:set_error_recovery() return true end
    function ctx:connect() bus.opens = bus.opens + 1; return true end
    function ctx:close() end
    function ctx:set_slave(s) self.slave = s end
    function ctx:set_response_timeout(s, us) self.timeout = s + us / 1e6 end
    local function call(c, op, addr, n)
      bus.calls[#bus.calls + 1] = { slave = c.slave, op = op, addr = addr, n = n, t = bus.t }
      if bus.broken then return nil, "Input/output error" end
      local handler = bus.slaves[c.slave]
      if not handler then bus.t = bus.t + c.timeout; return nil, "Connection timed out" end
      bus.t = bus.t + 0.02
      return handler(op, addr, n)
    end
    function ctx:write_register(a, v) return call(self, "write", a, v) end
    function ctx:read_registers(a, n) return call(self, "holding", a, n) end
    return ctx
  end
  function bus.service()
    return power.new({
      modbus = mb, clock = bus.clock,
      resolve = function() if bus.port then return bus.port end return nil, "nothing at USB 1-1.4" end,
      present = function(p) return p == bus.port end,
      report = function() bus.reports = bus.reports + 1 end,
      log = function(level, msg) bus.log[#bus.log + 1] = level .. ": " .. msg end,
    })
  end
  return bus
end

local function watchdog(op, addr, v)
  if op == "write" and addr == 1 and v == 10 then return true end
  return nil, "Illegal data address"
end

local function battery(regs)
  return function(op, addr)
    if op == "holding" and regs[addr] then return { regs[addr] } end
    return nil, "Illegal data address"
  end
end
local PACK = { [0x6000] = 1280, [0x6003] = 97, [0x6005] = 2500, [0x6006] = 3000 }

local function count(bus, slave, op)
  local n = 0
  for _, c in ipairs(bus.calls) do if c.slave == slave and (not op or c.op == op) then n = n + 1 end end
  return n
end

local function unit()
  eq("a timeout is unanswered", power.classify("Connection timed out"), "unanswered")
  eq("macOS's timeout too", power.classify("Operation timed out"), "unanswered")
  eq("an exception is an answer", power.classify("Illegal data address"), "error")
  eq("a bad CRC is an answer", power.classify("Invalid CRC"), "error")
  eq("EIO is the port", power.classify("Input/output error"), "port")

  -- ── the watchdog ─────────────────────────────────────────────────────────

  local bus = fake_bus()
  bus.slaves[0xC8] = watchdog
  local svc = bus.service()
  local wait = svc:tick()
  eq("fed at start", count(bus, 0xC8, "write"), 1)
  eq("the port opens with 9600 8N1 by path", table.concat(bus.opened_with, " "), "/dev/ttyUSB4 9600 N 8 1")
  eq("fed", svc:state().watchdog.state, "fed")
  check("next feed in two minutes", wait > 119 and wait <= 120, wait)
  bus.t = bus.t + 60; svc:tick()
  eq("not fed early", count(bus, 0xC8, "write"), 1)
  bus.t = bus.t + 61; svc:tick()
  eq("fed again on time", count(bus, 0xC8, "write"), 2)

  bus.slaves[0xC8] = nil
  bus.t = bus.t + 121; wait = svc:tick()
  eq("a watchdog that answered and stops is failing", svc:state().watchdog.state, "failing")
  check("retried in fifteen seconds", wait > 14 and wait <= 15, wait)
  bus.t = bus.t + 15; svc:tick()
  eq("failures counted", svc:state().watchdog.failures, 2)
  bus.slaves[0xC8] = watchdog
  bus.t = bus.t + 15; svc:tick()
  eq("recovers", svc:state().watchdog.state, "fed")
  eq("failures reset", svc:state().watchdog.failures, 0)

  -- The bench Pro on PoE: nothing at 0xC8, and nobody knows whether it has
  -- the watchdog. Feeding it must cost nothing and alarm nobody.
  bus = fake_bus()
  svc = bus.service()
  wait = svc:tick()
  eq("never answered is absent, not failing", svc:state().watchdog.state, "absent")
  check("a silent watchdog is asked at the ordinary interval", wait > 119 and wait <= 120, wait)
  for _ = 1, 5 do bus.t = bus.t + 120; svc:tick() end
  eq("so six asks in ten minutes", count(bus, 0xC8, "write"), 6)
  local loud, said = 0, 0
  for _, l in ipairs(bus.log) do
    if not l:find("^info") then loud = loud + 1 end
    if l:find("no watchdog answers", 1, true) then said = said + 1 end
  end
  eq("and nothing about it above info", loud, 0)
  eq("said once", said, 1)
  eq("and never reported", bus.reports, 0)

  -- ── a missing port, and one that goes away ───────────────────────────────

  bus = fake_bus()
  bus.port = nil
  bus.slaves[0xC8] = watchdog
  svc = bus.service()
  svc:tick()
  eq("no port is absent", svc:state().port.state, "absent")
  eq("and the watchdog is not fed", svc:state().watchdog.state, "absent")
  eq("nothing opened", bus.opens, 0)
  bus.port = "/dev/ttyUSB0"
  bus.t = bus.t + 5; svc:tick()
  eq("not reopened before its retry", bus.opens, 0)
  bus.t = bus.t + 11; svc:tick()
  eq("found once it enumerates", svc:state().port.device, "/dev/ttyUSB0")
  eq("and fed within seconds, not minutes", svc:state().watchdog.state, "fed")

  bus.broken = true
  bus.t = bus.t + 121; svc:tick()
  eq("EIO closes the port", svc:state().port.state, "error")
  eq("the watchdog is failing", svc:state().watchdog.state, "failing")
  bus.broken = false
  bus.t = bus.t + 15; svc:tick()
  eq("reopened after the retry", bus.opens, 2)
  eq("fed again", svc:state().watchdog.state, "fed")

  bus.port = "/dev/ttyUSB5"
  bus.t = bus.t + 121; svc:tick()
  eq("a renumbered tty is followed", svc:state().port.device, "/dev/ttyUSB5")
  eq("fed through it", svc:state().watchdog.state, "fed")

  -- ── the battery pack ─────────────────────────────────────────────────────

  bus = fake_bus()
  bus.slaves[0xC8], bus.slaves[0x6E] = watchdog, battery(PACK)
  svc = bus.service()
  svc:tick()
  local b = svc:state().battery
  eq("battery voltage", b.voltage, 12.8)
  eq("battery health", b.healthPercent, 97)
  eq("battery remaining percent", b.remainingPercent, 83.33)
  local reads = {}
  for _, c in ipairs(bus.calls) do if c.slave == 0x6E then reads[#reads + 1] = string.format("%x/%d", c.addr, c.n) end end
  eq("one register at a time, as ChirpStack reads them", table.concat(reads, " "), "6000/1 6003/1 6005/1 6006/1")
  eq("the watchdog goes first", bus.calls[1].slave, 0xC8)

  bus = fake_bus()
  bus.slaves[0xC8] = watchdog
  bus.slaves[0x6E] = battery({ [0x6000] = 1280, [0x6003] = 97, [0x6005] = 0, [0x6006] = 0 })
  svc = bus.service()
  svc:tick()
  eq("a zero full charge is no percentage, not a division by zero", svc:state().battery.remainingPercent, nil)

  bus = fake_bus()
  bus.slaves[0xC8] = watchdog
  svc = bus.service()
  svc:tick()
  eq("no pack fitted is absent", svc:state().battery.state, "absent")
  bus.t = bus.t + 1700; svc:tick()
  eq("and not asked every five minutes", count(bus, 0x6E), 1)
  bus.t = bus.t + 101; svc:tick()
  eq("but asked again in half an hour, in case one is fitted", count(bus, 0x6E), 2)

  -- ── telling Pulzar Cloud ──────────────────────────────────────────────────

  bus = fake_bus()
  bus.slaves[0xC8] = watchdog
  svc = bus.service()
  svc:tick()
  eq("the first state is not reported (the report loop's first run carries it)", bus.reports, 0)
  bus.slaves[0xC8] = nil
  bus.t = bus.t + 121; svc:tick()
  eq("a failing watchdog is reported at once", bus.reports, 1)
  bus.slaves[0xC8] = watchdog
  bus.t = bus.t + 15; svc:tick()
  eq("recovery within five minutes waits", bus.reports, 1)
  bus.t = bus.t + 10
  local w = svc:tick()
  check("the wait runs to the gap", w <= power.REPORT_GAP, w)
  bus.t = bus.t + power.REPORT_GAP; svc:tick()
  eq("and then goes", bus.reports, 2)
  bus.t = bus.t + 121; svc:tick()
  eq("nothing new, nothing sent", bus.reports, 2)

  bus = fake_bus()
  local pack = { [0x6000] = 1280, [0x6003] = 97, [0x6005] = 2500, [0x6006] = 3000 }
  bus.slaves[0xC8], bus.slaves[0x6E] = watchdog, battery(pack)
  svc = bus.service()
  svc:tick()
  pack[0x6005] = 2400
  bus.t = bus.t + 301; svc:tick()
  eq("a charge that drifts is not reported", bus.reports, 0)
  pack[0x6005] = 1400
  bus.t = bus.t + 301; svc:tick()
  eq("crossing 50% is", bus.reports, 1)

  -- ── what status prints ───────────────────────────────────────────────────

  bus = fake_bus()
  bus.slaves[0xC8] = watchdog
  svc = bus.service()
  svc:tick()
  local view = power.view(svc:state(), bus.t + 42)
  eq("fed so long ago", view.watchdog.fedAgo, 42)
  eq("running while fresh", view.running, true)
  eq("stale is not running", power.view(svc:state(), bus.t + 3 * power.STATE_EVERY + 1).running, false)
  eq("no record is not running", power.view(nil, 0).running, false)

  -- ── finding the port in sysfs ────────────────────────────────────────────

  local root = os.tmpname()
  os.remove(root)
  local iface = root .. "/1-1.4/1-1.4:1.0/ttyUSB4/tty/ttyUSB4"
  os.execute("mkdir -p '" .. iface .. "'")
  local function put(path, text) local f = io.open(path, "w"); f:write(text, "\n"); f:close() end
  put(root .. "/1-1.4/idVendor", "1a86"); put(root .. "/1-1.4/idProduct", "7523"); put(iface .. "/dev", "188:4")
  eq("the bridge's tty, by path", power.resolve("1-1.4", "1a86:7523", root), "/dev/ttyUSB4")
  check("present while its node is", power.present("1-1.4", "/dev/ttyUSB4", root))
  check("not another number", not power.present("1-1.4", "/dev/ttyUSB0", root))
  local p, why = power.resolve("1-1.4", "0403:6001", root)
  check("a different part at that port is refused", p == nil and why:find("1a86:7523", 1, true), why)
  check("nothing at another port", power.resolve("1-1.3", "", root) == nil)
  check("a path that is not a USB port is refused", power.resolve("1-1.4; rm -rf /", "", root) == nil)
  os.execute("rm -rf '" .. root .. "'")
end

-- ── sim: through libmodbus to pymodbus ─────────────────────────────────────

local function sim(dir)
  local mb = require("libmodbus")
  local f = io.open(dir .. "/port"); local port = f:read("*l"); f:close()
  local function writes()
    local out = {}
    local fw = io.open(dir .. "/writes")
    if fw then for line in fw:lines() do out[#out + 1] = line end fw:close() end
    return out
  end
  local function mute(list)
    local fm = io.open(dir .. "/muted", "w"); fm:write(table.concat(list, "\n"), "\n"); fm:close()
  end

  local t, reports = 0, 0
  local svc = power.new({
    modbus = mb, clock = function() return t end,
    resolve = function() return port end,
    present = function(p) return p == port end,
    report = function() reports = reports + 1 end,
  })

  svc:tick()
  local s = svc:state()
  eq("sim: the port opened", s.port.state, "open")
  eq("sim: the watchdog is fed", s.watchdog.state, "fed")
  eq("sim: and the power board saw register 1 = 10", writes()[1], "200 1 10")
  eq("sim: battery voltage over the wire", s.battery.voltage, 12.8)
  eq("sim: battery health", s.battery.healthPercent, 97)
  eq("sim: battery remaining", s.battery.remainingPercent, 83.33)

  mute({ 0xC8 })
  t = t + 121
  svc:tick()
  eq("sim: a muted watchdog is failing", svc:state().watchdog.state, "failing")
  check("sim: through a real timeout", svc:state().watchdog.error:find("timed out", 1, true), svc:state().watchdog.error)
  eq("sim: and it is reported", reports, 1)
  mute({})
  t = t + 15
  svc:tick()
  eq("sim: fed again once it answers", svc:state().watchdog.state, "fed")
  eq("sim: two feeds reached it", #writes(), 2)
  svc:close()

  -- The daemon's own entry point, so its glue is tested too: a mistake there
  -- is a watchdog nobody feeds. uloop and the board are faked; the port,
  -- libmodbus and the slave are the same real ones.
  local before = #writes()
  local ticks, waits = 0, {}
  local uloop = { init = function() end }
  function uloop.timer(cb)
    uloop.cb = cb
    return { set = function(_, ms) waits[#waits + 1] = ms end }
  end
  function uloop.run() for _ = 1, 2 do ticks = ticks + 1; uloop.cb() end end
  package.loaded["uloop"] = uloop
  local saved = { read_board = power.read_board, resolve = power.resolve, present = power.present,
                  exit = os.exit, popen = io.popen, arg = arg }
  power.read_board = function() return { PULZR_RAK_POWER_USB = "1-1.4", PULZR_RAK_POWER_ID = "1a86:7523" } end
  power.resolve = function() return port end
  power.present = function() return true end
  local logged = {}
  io.popen = function(cmd, mode)
    if cmd:find("^logger ") then
      return { write = function(_, ...) logged[#logged + 1] = table.concat({ ... }) end, close = function() end }
    end
    return saved.popen(cmd, mode)
  end
  os.exit = function(code) error({ exit = code }) end
  arg = { [0] = "pulzr-rak-power", "run" }
  local main = assert(loadfile(os.getenv("RAK_POWER_MAIN")))
  local ok, err = pcall(main)
  power.read_board, power.resolve, power.present = saved.read_board, saved.resolve, saved.present
  os.exit, io.popen, arg = saved.exit, saved.popen, saved.arg
  check("main: ran to its exit", not ok and type(err) == "table" and err.exit == 0, type(err) == "table" and err.exit or err)
  eq("main: ran the loop", ticks, 2)
  eq("main: fed the watchdog on its first tick", writes()[before + 1], "200 1 10")
  eq("main: and not again inside two minutes", #writes(), before + 1)
  check("main: rescheduled within the state interval",
    waits[1] and waits[1] > 0 and waits[1] <= power.STATE_EVERY * 1000, waits[1])
  local opened = false
  for _, l in ipairs(logged) do if l:find("power board port " .. port .. " open", 1, true) then opened = true end end
  check("main: logged the port it opened", opened, table.concat(logged, " | "))
end

unit()
local dir = os.getenv("RAK_POWER_SIM")
if dir and dir ~= "" then sim(dir) end
print(passed .. " passed" .. (failed > 0 and (", " .. failed .. " failed") or ""))
os.exit(failed > 0 and 1 or 0)
