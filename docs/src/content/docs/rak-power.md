---
title: "The RAK7289CV2 power board"
description: "The RAK7289CV2 (WisGate Edge Pro) reaches its power board over Modbus RTU, through a CH340 USB-serial bridge inside the case."
---

The RAK7289CV2 (WisGate Edge Pro) reaches its power board over Modbus RTU,
through a CH340 USB-serial bridge inside the case. Two things sit on that bus:

- the power board's **hardware watchdog**. On the newer hardware revision, a
  unit on DC power whose OS does not feed it loses its power.
- the optional **RAK battery pack**.

`pulzr-rak-power` feeds the one, reads the other, and reports both to
Pulzr Cloud.

It is RAK-specific and deliberately small. It is not a general RS485 or
Modbus service. The slaves, the registers and the line settings are RAK's and
fixed, and nothing about it is configurable. A gateway with real IO gets its
own design, not this one grown.

## What is known, and from where

Nothing on this bus has been seen answering. The design rests on three
sources and one bench probe.

- **ChirpStack's RAK support**, the one known-working user of this bus:
  `chirpstack/chirpstack-gateway-utils`, `src/rak/watchdog.rs` and
  `src/rak/battery.rs`. They use Modbus RTU at 9600 8N1, with a 100 ms timeout
  per request.
  - Slave `0xC8` (200) is the watchdog. Writing `10` to holding register
    `0x0001` feeds it.
  - Slave `0x6E` (110) is the battery pack. ChirpStack reads four holding
    registers, one at a time: `0x6000` voltage ×0.01 V, `0x6003` health %,
    `0x6005` remaining capacity, `0x6006` full-charge capacity.
- **chirpstack/chirpstack-gateway-os#155.** RAK support says the newer
  RAK7289V2/CV2 revision has a hardware watchdog and "fully reboots every 10
  minutes" unless WisGateOS feeds it. The reporter saw a unit on 12 V DC go
  off after about ten minutes and stay off, and saw no problem on PoE.
  ChirpStack feeds every 5 minutes from cron, and the reporter confirmed that
  keeps a DC unit up. The dmesg in that issue, from a RAK7289V2, shows the
  bridge: `ch341 1-1.4:1.0: ch341-uart converter detected`, so a CH340
  (`1a86:7523`) at port `1-1.4` on the internal hub. RAK's instructions there
  for disabling the watchdog name its WisGateOS daemon, `spregread`.
- **RAK's own WisGateOS 2.3.1** (RAK636 image, read statically, not run).
  - `/etc/hotplug.d/usb/11-symlinks` maps `1-1.4:1.0` to `/dev/ttyRS485`, so
    the CH340 is RAK's RS485 port. The same file has LoRa card 0 at `1-1.2`,
    card 1 at `1-1.3`, and the EG95's AT port at `1-1.1:1.2`.
  - The bus is driven by `/usr/sbin/spregread`, which uses libmodbus. Its init
    script runs it only when the unit's factory capabilities
    (`einfo.dev.caps`) include `solar_battery` (battery) or `hwwdg`
    (watchdog). It first runs `spregread -i /dev/ttyRS485 -e 0 -E 1 -F`,
    whose help says "force off WDT". So the watchdog can be switched off over
    Modbus as well as fed. RAK's `stop_wdt_service` does the same, presumably
    so a long operation such as an upgrade is not cut off. That register
    is not known here: the binary has not been disassembled.
  - `/etc/config/spregread`: battery at device 110, address `0x6000`, read
    every 10 s; `wdtcfg` timeout `10`. That 10 matches the value ChirpStack
    writes to `0x0001`, so the feed is most likely the watchdog's timeout in
    minutes, rewritten.
- **The bench Pro** (2026-10-26, PulzrOS 0.1.0, with
  `kmod-usb-serial-ch341` from the 24.10.0 feed, on PoE). The CH340 came up as
  `/dev/ttyUSB4` at `1-1.4`, with the EG95 on `ttyUSB0`-`3`. At 9600 8N1,
  nothing answered:
  - a read of `0x0001` at slave 200
  - ChirpStack's feed (function 06, `0x0001` = 10)
  - a read of `0x6000` at slave 110

  The line was silent for 5 s idle, and its own TX did not echo. No battery
  pack was fitted, so 110's silence is expected. The unit's factory
  descriptor (mtd `factory` at `0x2000`) lists `DEV_CAPS` as
  `dying_gasp solar_battery hwwdg lbt`, so it has the watchdog and the
  battery hardware. Its watchdog was silent on PoE, so a unit that has one
  may not answer, or may not run it, off DC. A Lite's descriptor lists only
  `breathing_light`.

Still open:

| Question | What depends on it |
|---|---|
| Does a newer-revision unit on DC answer at 200, and does the feed keep it up? | Everything here. ChirpStack's code and the reporter in #155 are the only evidence. |
| Does a fitted battery pack answer at 110 with those registers? | The battery facts on the gateway page. |
| What does register `0x0001 = 10` mean? | Most likely the timeout in minutes, matching RAK's `wdtcfg timeout 10`. Feeding every two minutes is safe under any reading that keeps ChirpStack's five working. |
| What does the watchdog do during a long sysupgrade, or in failsafe or recovery? | Nothing feeds it in those states. A flash takes about four minutes on this board and the last feed is at most two minutes before it, so it should fit inside ten. Recovery on DC power will not fit. RAK switches the watchdog off over Modbus first (`spregread -F`), but which register that writes is not known. |
| Does the watchdog answer, or run at all, on PoE? | Whether a silent watchdog can ever be a warning. The bench unit has one and was silent on PoE, so for now silence is never a fault. |

## Design

**One owner, one request at a time.** The watchdog and the battery pack are
slaves of one master, and a second master on the line corrupts both. So one
process opens the port, and nothing else does:

- The MQTT agent's `rak-power` op prints the daemon's record. It does not read
  the bus.
- The ModemManager tty hotplug override (`boards/common/files/etc/hotplug.d/tty/25-modemmanager-tty`)
  skips the bridge's tty, so ModemManager never writes AT probes onto the bus.

**The port is found by USB path, not by number.** On a CV2 the EG95 modem
takes four ttyUSB nodes. Which of the modem and the CH340 is `ttyUSB0`
depends on which driver binds first, and ChirpStack hardcodes
`/dev/ttyUSB0`. The daemon looks under
`/sys/bus/usb/devices/1-1.4/1-1.4:1.0/` for the tty, checks the vid:pid, and
looks again whenever the node goes away. On the bench Pro the CH340 was
`ttyUSB4`.

**Only boards that declare it.** `PULZR_RAK_POWER_USB` and
`PULZR_RAK_POWER_ID` live in `boards/common/rakwireless.conf`, empty by
default, and only `boards/rak7289cv2/board.conf` sets them and adds
`PACKAGES_RAK_POWER`. No other board carries the package, and the init script
starts nothing on a board that does not set the port.

**The watchdog comes first.**

- It is fed every 120 s. Once it has answered, a failure is retried every
  15 s. The watchdog allows ten minutes, so this survives four missed feeds
  where ChirpStack's cron survives one.
- A tick always tries the watchdog before the battery pack.
- The init script starts the daemon at `START=15`, with no gate on adoption,
  network or broker, and respawns it with no limit.

**Watchdog states.**

| State | Meaning |
|---|---|
| `fed` | The last feed succeeded. |
| `failing` | It answered earlier in this boot and has stopped. On DC power the unit is ten minutes from a power cut. Retried every 15 s, logged as an error, reported at once. |
| `absent` | It has never answered this boot. An older revision has no watchdog, and one that has it may not answer on PoE (the bench unit does not), so this is not a fault: logged once at info, never reported on its own, and still fed every 2 minutes in case it is there. While the port itself is missing, as it is for the first seconds of boot, it is retried every 10 s instead. |

**The battery pack** is an optional accessory, so one that has never answered
is `absent` and is asked every 30 minutes, in case one is fitted later, instead
of every 5. Pulzr Cloud shows nothing for a pack that is `absent`.

**Telling Pulzr Cloud.** The record rides `pulzr-claim report` as
`facts.rakPower`, the same report that carries the rest of the gateway's
health. That report goes every six hours. The daemon also asks for one when
the summary changes:

- the port state
- the watchdog state
- the battery pack's state, or its charge crossing 50, 20 or 10 %

Those reports are at most one every five minutes. The first settled state is
not one of them, because the report loop's own first report goes 30 seconds
after boot. A voltage that drifts waits for the six-hourly report, or for
Refresh on the gateway page, which asks over MQTT.

**Times are ages.** The record says `fedAgo`, not a timestamp. The gateway's
clock is 1970 until NTP answers, and the watchdog is fed from the first seconds
of boot. Pulzr Cloud counts back from when the record arrived.

## Why Lua

The task was a maintained Modbus library rather than hand-rolled RTU framing
and CRC. The one OpenWrt packages is libmodbus 3.1.8, and its bindings are:

| Binding | Size on mipsel | Usable here |
|---|---|---|
| `lua-libmodbus` 0.7 | 8 KB, plus `liblua` (64 KB) | Yes |
| `python3-libmodbus` | needs `python3-light`, megabytes | No: does not fit a 16 MB board |
| ucode | none exists | No: writing one means compiling a package per architecture, which this feed does not do |

So the daemon is Lua 5.1. libmodbus does the framing, CRC, timeouts and error
recovery (`ERROR_RECOVERY_PROTOCOL`: flush and wait out the timeout after a bad
frame). The rest is also OpenWrt packages: `lua-cjson` writes the record, and
`libubox-lua`'s uloop runs the timer. With `kmod-usb-serial-ch341`, which the
package depends on, it adds about 100 KB compressed, to the RAK7289CV2 image
only.

Release images strip whole-line `--` comments from Lua files
(`scripts/strip-lua-comments.py`, called from `harden-payload.sh`). They do not
compile Lua to bytecode. That would need `luac` from OpenWrt's exact Lua build,
whose LNUM patch changes the bytecode format.

## Reading it on the gateway

```sh
pulzr-rak-power status    # the record, ages in seconds
logread -e rak-power        # port, watchdog and battery state changes
```

## Tests

`scripts/test-rak-power.sh` runs two halves.

**Unit half.** It drives the scheduler and the battery arithmetic against a
fake bus whose answers and clock the test chooses. It covers:

- feed timing and retries
- `failing` versus `absent`, and a silent watchdog fed without an alarm
- a port that is missing, breaks or renumbers
- the battery pack's register order, a missing pack, and report bands
- report rate-limiting
- finding the tty in a fake sysfs

**Simulated half.** It builds lua-libmodbus 0.7 from the tarball whose hash
is OpenWrt's `PKG_HASH`, and links it to the host's libmodbus. It then
talks over a pty pair to a pymodbus power board
(`scripts/rak-power-test/simulator.py`), an independent framer and decoder.
It checks:

- the watchdog write the simulated power board receives
- the battery values over the wire
- a watchdog that falls silent mid-run
- the daemon's own entry point feeding the watchdog

`RAK_POWER_UNIT_ONLY=1` runs only the unit half, on a machine without a C
compiler or pymodbus.

What neither half covers is the hardware itself: the CH340 under this kernel,
real line timing, and the power board's own behaviour.
