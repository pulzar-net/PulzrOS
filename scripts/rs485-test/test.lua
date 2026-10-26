-- parkeze-rs485's tests. Run by scripts/test-rs485.sh, which sets package.path
-- to the feed and, for the simulated bus, package.cpath to a lua-libmodbus
-- built from the release OpenWrt ships.
--
--   unit   the scheduling, the config and the decoding, against a fake bus
--          whose every answer and every second is chosen here
--   sim    the same service through real libmodbus to a pymodbus slave on a
--          pty pair (RS485_SIM=<simulator dir>)

local rs485 = require("parkeze.rs485")

local passed, failed = 0, 0
local function check(what, ok, detail)
  if ok then passed = passed + 1
  else failed = failed + 1; print("FAIL: " .. what .. (detail and (" (" .. tostring(detail) .. ")") or "")) end
end
local function eq(what, got, want) check(what, got == want, "got " .. tostring(got) .. ", want " .. tostring(want)) end

local BOARD = { PARKEZE_RS485 = "1-1.4", PARKEZE_RS485_ID = "1a86:7523",
                PARKEZE_RS485_WATCHDOG = "200", PARKEZE_RS485_BATTERY = "110" }

-- ── a bus whose answers and time are ours ──────────────────────────────────

local function fake_bus()
  local bus = { t = 1000, calls = {}, slaves = {}, port = "/dev/ttyUSB4", opens = 0 }
  function bus.clock() return bus.t end
  local mb = { ERROR_RECOVERY_PROTOCOL = 4 }
  function mb.new_rtu(path, baud, parity, data, stop)
    bus.opened_with = { path, baud, parity, data, stop }
    local ctx = { slave = nil, timeout = 0.5 }
    function ctx:set_error_recovery() return true end
    function ctx:connect() bus.opens = bus.opens + 1; return true end
    function ctx:close() end
    function ctx:set_slave(s) self.slave = s end
    function ctx:set_response_timeout(s, us) self.timeout = s + us / 1e6 end
    local function call(ctx_, op, addr, n)
      bus.calls[#bus.calls + 1] = { slave = ctx_.slave, op = op, addr = addr, n = n, t = bus.t }
      if bus.broken then return nil, "Input/output error" end
      local handler = bus.slaves[ctx_.slave]
      if not handler then bus.t = bus.t + ctx_.timeout; return nil, "Connection timed out" end
      bus.t = bus.t + 0.02
      return handler(op, addr, n)
    end
    function ctx:write_register(a, v) return call(self, "write", a, v) end
    function ctx:read_registers(a, n) return call(self, "holding", a, n) end
    function ctx:read_input_registers(a, n) return call(self, "input", a, n) end
    function ctx:read_bits(a, n) return call(self, "coil", a, n) end
    function ctx:read_input_bits(a, n) return call(self, "discrete", a, n) end
    return ctx
  end
  bus.mb = mb
  bus.reports = 0
  bus.log = {}
  function bus.service(cfg)
    return rs485.new(cfg, {
      modbus = mb, clock = bus.clock,
      resolve = function() if bus.port then return bus.port end return nil, "nothing at USB 1-1.4" end,
      present = function(p) return p == bus.port end,
      report = function() bus.reports = bus.reports + 1 end,
      log = function(level, msg) bus.log[#bus.log + 1] = level .. ": " .. msg end,
    })
  end
  return bus
end

local function watchdog_ok(op, addr, v)
  if op == "write" and addr == 1 and v == 10 then return true end
  return nil, "Illegal data address"
end

local function battery(op, addr)
  local regs = { [0x6000] = 1280, [0x6003] = 97, [0x6005] = 2500, [0x6006] = 3000 }
  if op == "holding" and regs[addr] then return { regs[addr] } end
  return nil, "Illegal data address"
end

local function writes_to(bus, slave)
  local n = 0
  for _, c in ipairs(bus.calls) do if c.slave == slave and c.op == "write" then n = n + 1 end end
  return n
end

-- ── unit: registers and config ─────────────────────────────────────────────

local function unit()
  local r = rs485.parse_register("voltage:input:0x0010:u16:0.1:V")
  check("a register parses", r and r.table == "input" and r.address == 16 and r.scale == 0.1 and r.unit == "V")
  r = rs485.parse_register("energy:holding:40:u32le::kWh")
  check("an empty scale is no scale", r and r.words == 2 and r.scale == nil and r.unit == "kWh")
  r = rs485.parse_register("door:discrete:2")
  check("a discrete input is a bool", r and r.type == "bool" and r.words == 1)
  for _, bad in ipairs({ "x:holding:65535:u32", "x:holding:70000", "x:holding:1:u64", "x y:holding:1",
                         "x:coil:1:u16", "x:holding:1:u16:abc", "x:holding:1:u16:1:V;rm", "x:bogus:1",
                         "x:holding:1:u16:1:V:extra" }) do
    check("refuses " .. bad, rs485.parse_register(bad) == nil)
  end

  local cfg = rs485.config(BOARD, {
    rs485 = { [".type"] = "rs485", baud = "9600", parity = "none", stopbits = "1" },
    a = { [".type"] = "modbus", [".index"] = 3, name = "meter", slave = "1", interval = "30",
          register = { "v:holding:0:u16:0.1:V", "t:holding:1:s16" } },
    b = { [".type"] = "modbus", [".index"] = 4, name = "clash", slave = "200", register = "v:holding:0" },
    c = { [".type"] = "modbus", [".index"] = 5, name = "meter", slave = "2", register = "v:holding:0" },
    d = { [".type"] = "modbus", [".index"] = 6, name = "off", slave = "3", enabled = "0", register = "v:holding:0" },
    e = { [".type"] = "modbus", [".index"] = 7, name = "single", slave = "4", register = "v:input:5" },
    f = { [".type"] = "modbus", [".index"] = 8, name = "typo", slave = "5", register = { "v:holding:0", "w:hold:1" } },
    g = { [".type"] = "modbus", [".index"] = 9, name = "empty", slave = "6" },
  })
  eq("bus defaults hold", cfg.baud .. cfg.parity .. cfg.stopbits, "9600N1")
  eq("watchdog from the board", cfg.watchdog and cfg.watchdog.slave, 200)
  eq("battery from the board", cfg.battery and cfg.battery.slave, 110)
  local names = {}
  for _, d in ipairs(cfg.devices) do names[#names + 1] = d.name end
  eq("devices in UCI order, bad ones out", table.concat(names, ","), "meter,single,typo")
  eq("a device's interval", cfg.devices[1].interval, 30)
  eq("a single register is a list of one", #cfg.devices[2].registers, 1)
  eq("a bad register drops only itself", #cfg.devices[3].registers, 1)
  local problems = table.concat(cfg.problems, "\n")
  check("a slave on the watchdog's address is refused", problems:find("slave 200 is the watchdog", 1, true), problems)
  check("a duplicate name is refused", problems:find("device meter is named twice", 1, true), problems)
  check("a register typo is named", problems:find("'w:hold:1'", 1, true), problems)
  check("a device with no registers is named", problems:find("device empty: no registers", 1, true), problems)
  check("an off device is no problem", not problems:find("off", 1, true), problems)

  cfg = rs485.config(BOARD, { rs485 = { [".type"] = "rs485", baud = "9601", parity = "mark" } })
  eq("a non-standard baud falls back", cfg.baud, 9600)
  eq("an unknown parity falls back", cfg.parity, "N")
  eq("both are named", #cfg.problems, 2)
  check("no board port, no usb", rs485.config({}, {}).usb == "")

  eq("a timeout is unanswered", rs485.classify("Connection timed out"), "unanswered")
  eq("macOS's timeout too", rs485.classify("Operation timed out"), "unanswered")
  eq("an exception is an answer", rs485.classify("Illegal data address"), "error")
  eq("a bad CRC is an answer", rs485.classify("Invalid CRC"), "error")
  eq("EIO is the port", rs485.classify("Input/output error"), "port")

  local function dec(t, words, scale) return rs485.decode({}, { type = t, scale = scale }, words) end
  eq("u16 scaled", dec("u16", { 1280 }, 0.01), 12.8)
  eq("s16 negative", dec("s16", { 0xFFF6 }), -10)
  eq("u32 high word first", dec("u32", { 1, 0x86A0 }), 100000)
  eq("u32le low word first", dec("u32le", { 0x86A0, 1 }), 100000)
  eq("s32 negative", dec("s32", { 0xFFFF, 0xFF38 }), -200)
  eq("s32le negative", dec("s32le", { 0xFF38, 0xFFFF }), -200)
  eq("s32 at its minimum", dec("s32", { 0x8000, 0 }), -2147483648)
  eq("a ten-digit counter keeps every digit", dec("u32", { 0xFFFF, 0xFFFF }), 4294967295)
  eq("and scaled, its last digit", dec("u32", { 0xFFFF, 0xFFFF }, 0.1), 429496729.5)
  eq("a NaN is not a reading",
     rs485.decode({ get_f32 = function() return 0 / 0 end }, { type = "f32" }, { 0x7FC0, 0 }), nil)

  -- ── the watchdog ─────────────────────────────────────────────────────────

  local bus = fake_bus()
  bus.slaves[200] = watchdog_ok
  local svc = bus.service(rs485.config(BOARD, {}))
  local wait = svc:tick()
  eq("fed at start", writes_to(bus, 200), 1)
  eq("the port opens with 9600 8N1 by path", table.concat(bus.opened_with, " "), "/dev/ttyUSB4 9600 N 8 1")
  eq("fed", svc:state().watchdog.state, "fed")
  check("next feed in two minutes", wait > 119 and wait <= 120, wait)
  bus.t = bus.t + 60; svc:tick()
  eq("not fed early", writes_to(bus, 200), 1)
  bus.t = bus.t + 61; svc:tick()
  eq("fed again on time", writes_to(bus, 200), 2)

  bus.slaves[200] = nil
  bus.t = bus.t + 121; wait = svc:tick()
  eq("a silent watchdog after a feed is failing", svc:state().watchdog.state, "failing")
  check("retried in fifteen seconds", wait > 14 and wait <= 15, wait)
  eq("the battery, never answering, is absent", svc:state().battery.state, "absent")
  bus.t = bus.t + 15; svc:tick()
  eq("failures counted", svc:state().watchdog.failures, 2)
  bus.slaves[200] = watchdog_ok
  bus.t = bus.t + 15; svc:tick()
  eq("recovers", svc:state().watchdog.state, "fed")
  eq("failures reset", svc:state().watchdog.failures, 0)

  bus = fake_bus()
  svc = bus.service(rs485.config(BOARD, {}))
  wait = svc:tick()
  eq("never answered is absent, not failing", svc:state().watchdog.state, "absent")
  -- The bench Pro on PoE: nothing at 0xC8, and nobody knows whether it has
  -- the watchdog. Feeding it must cost nothing and alarm nobody.
  check("a silent watchdog is asked at the ordinary interval", wait > 119 and wait <= 120, wait)
  for _ = 1, 5 do bus.t = bus.t + 120; svc:tick() end
  eq("so six asks in ten minutes", writes_to(bus, 200), 6)
  local loud = 0
  for _, l in ipairs(bus.log) do
    if l:find("watchdog", 1, true) and not l:find("^info") then loud = loud + 1 end
  end
  eq("and nothing about it above info", loud, 0)
  local said = 0
  for _, l in ipairs(bus.log) do if l:find("no watchdog answers", 1, true) then said = said + 1 end end
  eq("said once", said, 1)
  eq("and never reported", bus.reports, 0)

  -- ── a missing port, and one that goes away ───────────────────────────────

  bus = fake_bus()
  bus.port = nil
  bus.slaves[200] = watchdog_ok
  svc = bus.service(rs485.config(BOARD, {}))
  svc:tick()
  eq("no port is absent", svc:state().port.state, "absent")
  eq("and the watchdog is not fed", svc:state().watchdog.state, "absent")
  eq("nothing opened", bus.opens, 0)
  bus.port = "/dev/ttyUSB0"
  bus.t = bus.t + 5; svc:tick()
  eq("not reopened before its retry", bus.opens, 0)
  bus.t = bus.t + 11; svc:tick()
  eq("found once it enumerates", svc:state().port.device, "/dev/ttyUSB0")
  eq("and fed", svc:state().watchdog.state, "fed")

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

  -- ── the battery ──────────────────────────────────────────────────────────

  bus = fake_bus()
  bus.slaves[200], bus.slaves[110] = watchdog_ok, battery
  svc = bus.service(rs485.config(BOARD, {}))
  svc:tick()
  local b = svc:state().battery
  eq("battery voltage", b.voltage, 12.8)
  eq("battery health", b.healthPercent, 97)
  eq("battery remaining percent", b.remainingPercent, 83.33)
  local reads = {}
  for _, c in ipairs(bus.calls) do if c.slave == 110 then reads[#reads + 1] = string.format("%x/%d", c.addr, c.n) end end
  eq("one register at a time, as ChirpStack reads them", table.concat(reads, " "), "6000/1 6003/1 6005/1 6006/1")

  bus = fake_bus()
  bus.slaves[200] = watchdog_ok
  svc = bus.service(rs485.config(BOARD, {}))
  svc:tick()
  bus.t = bus.t + 1700; svc:tick()
  local asked = 0
  for _, c in ipairs(bus.calls) do if c.slave == 110 then asked = asked + 1 end end
  eq("an absent battery is not asked every five minutes", asked, 1)

  -- ── devices, and the watchdog first ──────────────────────────────────────

  local sections = {
    m = { [".type"] = "modbus", [".index"] = 1, name = "meter", slave = "1", interval = "60",
          register = { "v:holding:0:u16:0.1:V", "bad:holding:99", "t:holding:1:s16", "n:input:5" } },
    s = { [".type"] = "modbus", [".index"] = 2, name = "silent", slave = "2", timeout = "5000",
          register = { "a:holding:0", "b:holding:1", "c:holding:2" } },
  }
  bus = fake_bus()
  bus.slaves[200] = watchdog_ok
  bus.slaves[1] = function(op, addr)
    local regs = { holding = { [0] = 2301, [1] = 0xFFF6 }, input = { [5] = 42 } }
    local v = regs[op] and regs[op][addr]
    if v then return { v } end
    return nil, "Illegal data address"
  end
  svc = bus.service(rs485.config({ PARKEZE_RS485 = "1-1.4", PARKEZE_RS485_WATCHDOG = "200" }, sections))
  svc:tick()
  local devs = svc:state().devices
  eq("an exception makes the meter partial", devs[1].state, "partial")
  eq("the register before it reads", devs[1].readings[1].value, 230.1)
  eq("the exception is on its register", devs[1].readings[2].error, "Illegal data address")
  eq("the registers after it still read", devs[1].readings[3].value, -10)
  eq("an input register reads", devs[1].readings[4].value, 42)
  eq("a silent slave is unanswered", devs[2].state, "unanswered")
  local silent = 0
  for _, c in ipairs(bus.calls) do if c.slave == 2 then silent = silent + 1 end end
  eq("a silent slave is asked once per poll, not once per register", silent, 1)

  -- A slave that takes its whole five-second timeout on every register, and a
  -- watchdog due in the middle of the poll: it must not wait for the rest.
  bus = fake_bus()
  bus.slaves[200] = watchdog_ok
  local slow = 0
  bus.slaves[3] = function() slow = slow + 1; bus.t = bus.t + 50; return { 1 } end
  svc = bus.service(rs485.config({ PARKEZE_RS485 = "1-1.4", PARKEZE_RS485_WATCHDOG = "200" }, {
    s = { [".type"] = "modbus", name = "slow", slave = "3", interval = "5", register = { "a:holding:0", "b:holding:1", "c:holding:2" } },
    t = { [".type"] = "modbus", name = "slow2", slave = "3", interval = "5", register = { "a:holding:0", "b:holding:1", "c:holding:2" } },
  }))
  svc:tick()
  local last_feed, gap = nil, 0
  for _, c in ipairs(bus.calls) do
    if c.slave == 200 then
      if last_feed then gap = math.max(gap, c.t - last_feed) end
      last_feed = c.t
    end
  end
  check("a slow device delays a feed by one device's poll at most", gap <= 120 + 150 + 1, gap)
  check("and the watchdog was fed between the two", writes_to(bus, 200) >= 2, writes_to(bus, 200))

  -- ── telling parkeze.net ──────────────────────────────────────────────────

  bus = fake_bus()
  bus.slaves[200] = watchdog_ok
  svc = bus.service(rs485.config(BOARD, {}))
  svc:tick()
  eq("the first state is not reported (the report loop's first run carries it)", bus.reports, 0)
  bus.slaves[200] = nil
  bus.t = bus.t + 121; svc:tick()
  eq("a failing watchdog is reported at once", bus.reports, 1)
  bus.slaves[200] = watchdog_ok
  bus.t = bus.t + 15; svc:tick()
  eq("recovery within five minutes waits", bus.reports, 1)
  local w
  bus.t = bus.t + 10; w = svc:tick()
  check("the wait runs to the gap", w <= rs485.REPORT_GAP, w)
  bus.t = bus.t + rs485.REPORT_GAP; svc:tick()
  eq("and then goes", bus.reports, 2)
  bus.t = bus.t + 121; svc:tick()
  eq("nothing new, nothing sent", bus.reports, 2)

  -- ── what status prints ───────────────────────────────────────────────────

  bus = fake_bus()
  bus.slaves[200] = watchdog_ok
  svc = bus.service(rs485.config(BOARD, {}))
  svc:tick()
  local view = rs485.view(svc:state(), bus.t + 42)
  eq("fed so long ago", view.watchdog.fedAgo, 42)
  eq("running while fresh", view.running, true)
  eq("stale is not running", rs485.view(svc:state(), bus.t + 3 * rs485.STATE_EVERY + 1).running, false)
  eq("no record is not running", rs485.view(nil, 0).running, false)

  -- ── finding the port in sysfs ────────────────────────────────────────────

  local root = os.tmpname()
  os.remove(root)
  local iface = root .. "/1-1.4/1-1.4:1.0/ttyUSB4/tty/ttyUSB4"
  os.execute("mkdir -p '" .. iface .. "'")
  local function put(path, text) local f = io.open(path, "w"); f:write(text, "\n"); f:close() end
  put(root .. "/1-1.4/idVendor", "1a86"); put(root .. "/1-1.4/idProduct", "7523"); put(iface .. "/dev", "188:4")
  eq("the bridge's tty, by path", rs485.resolve("1-1.4", "1a86:7523", root), "/dev/ttyUSB4")
  check("present while its node is", rs485.present("1-1.4", "/dev/ttyUSB4", root))
  check("not another number", not rs485.present("1-1.4", "/dev/ttyUSB0", root))
  local p, why = rs485.resolve("1-1.4", "0403:6001", root)
  check("a different part at that port is refused", p == nil and why:find("1a86:7523", 1, true), why)
  check("nothing at another port", rs485.resolve("1-1.3", "", root) == nil)
  check("a path that is not a USB port is refused", rs485.resolve("1-1.4; rm -rf /", "", root) == nil)
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

  local t = 0
  local reports = 0
  local cfg = rs485.config(BOARD, {
    m = { [".type"] = "modbus", [".index"] = 1, name = "meter", slave = "1", timeout = "300",
          register = { "voltage:holding:0:u16:0.1:V", "temperature:holding:1:s16::C", "energy:holding:2:u32::Wh",
                       "power:holding:10:f32::kW", "current:holding:20:f32le::A", "energy2:holding:30:u32le",
                       "offset:holding:40:s32", "missing:holding:99", "count:input:5", "relay:coil:3", "door:discrete:2" } },
    g = { [".type"] = "modbus", [".index"] = 2, name = "ghost", slave = "2", timeout = "200",
          register = { "a:holding:0", "b:holding:1" } },
  })
  check("the sim config is clean", #cfg.problems == 0, table.concat(cfg.problems, "; "))
  local svc = rs485.new(cfg, {
    modbus = mb, clock = function() return t end,
    resolve = function() return port end,
    present = function(p) return p == port end,
    report = function() reports = reports + 1 end,
    log = function() end,
  })

  local started = os.clock()
  svc:tick()
  local s = svc:state()
  eq("sim: the port opened", s.port.state, "open")
  eq("sim: the watchdog is fed", s.watchdog.state, "fed")
  eq("sim: and the power board saw register 1 = 10", writes()[1], "200 1 10")
  eq("sim: battery voltage over the wire", s.battery.voltage, 12.8)
  eq("sim: battery health", s.battery.healthPercent, 97)
  eq("sim: battery remaining", s.battery.remainingPercent, 83.33)

  local by = {}
  for _, r in ipairs(s.devices[1].readings) do by[r.name] = r end
  eq("sim: u16 scaled", by.voltage.value, 230.1)
  eq("sim: s16", by.temperature.value, -10)
  eq("sim: u32", by.energy.value, 100000)
  eq("sim: f32 high word first", by.power.value, 3.5)
  eq("sim: f32 low word first", by.current.value, -1.25)
  eq("sim: u32le", by.energy2.value, 100000)
  eq("sim: s32", by.offset.value, -200)
  eq("sim: a register that is not there is the slave's exception", by.missing.error, "Illegal data address")
  eq("sim: input register", by.count.value, 42)
  eq("sim: coil", by.relay.value, 1)
  eq("sim: discrete input", by.door.value, 1)
  eq("sim: so the meter is partial", s.devices[1].state, "partial")
  eq("sim: a slave that is not there is unanswered", s.devices[2].state, "unanswered")
  check("sim: and costs one timeout, not one per register", s.devices[2].readings[2].error ~= nil)

  -- The watchdog falls silent after it has been fed.
  mute({ 200 })
  t = t + 121
  svc:tick()
  eq("sim: a muted watchdog is failing", svc:state().watchdog.state, "failing")
  eq("sim: and it is reported", reports, 1)
  mute({})
  t = t + 15
  svc:tick()
  eq("sim: fed again once it answers", svc:state().watchdog.state, "fed")
  eq("sim: two feeds reached it", #writes(), 2)
  svc:close()
  io.write(string.format("sim: %.2fs of CPU for the run\n", os.clock() - started))

  -- The daemon's own entry point, so its glue is tested too: a mistake there
  -- is a watchdog nobody feeds. UCI, uloop and the board are faked; the port,
  -- libmodbus and the slave are the same real ones.
  local before = #writes()
  local ticks, waits = 0, {}
  package.loaded["uci"] = { cursor = function()
    return { get_all = function() return { rs485 = { [".type"] = "rs485", baud = "9600" } } end }
  end }
  package.loaded["uloop"] = {
    init = function() end,
    timer = function(cb)
      local timer = { set = function(_, ms) waits[#waits + 1] = ms end }
      package.loaded["uloop"].cb = cb
      return timer
    end,
    run = function() for _ = 1, 2 do ticks = ticks + 1; package.loaded["uloop"].cb() end end,
  }
  local saved = { read_board = rs485.read_board, resolve = rs485.resolve, present = rs485.present,
                  exit = os.exit, popen = io.popen, arg = arg }
  rs485.read_board = function() return BOARD end
  rs485.resolve = function() return port end
  rs485.present = function() return true end
  local logged = {}
  io.popen = function(cmd, mode)
    if cmd:find("^logger ") then
      return { write = function(_, ...) logged[#logged + 1] = table.concat({ ... }) end, close = function() end }
    end
    return saved.popen(cmd, mode)
  end
  os.exit = function(code) error({ exit = code }) end
  arg = { [0] = "parkeze-rs485", "run" }
  local main = assert(loadfile(os.getenv("RS485_MAIN")))
  local ok, err = pcall(main)
  rs485.read_board, rs485.resolve, rs485.present = saved.read_board, saved.resolve, saved.present
  os.exit, io.popen, arg = saved.exit, saved.popen, saved.arg
  check("main: ran to its exit", not ok and type(err) == "table" and err.exit == 0, type(err) == "table" and err.exit or err)
  eq("main: ran the loop", ticks, 2)
  eq("main: fed the watchdog on its first tick", writes()[before + 1], "200 1 10")
  eq("main: and not again inside two minutes", #writes(), before + 1)
  check("main: rescheduled within the state interval", waits[1] and waits[1] > 0 and waits[1] <= rs485.STATE_EVERY * 1000, waits[1])
  local opened = false
  for _, l in ipairs(logged) do if l:find("RS485 port " .. port .. " open", 1, true) then opened = true end end
  check("main: logged the port it opened", opened, table.concat(logged, " | "))
end

unit()
local dir = os.getenv("RS485_SIM")
if dir and dir ~= "" then sim(dir) end
print(passed .. " passed" .. (failed > 0 and (", " .. failed .. " failed") or ""))
os.exit(failed > 0 and 1 or 0)
