# Plugged-in radios

A PulzrOS gateway notices a Zigbee, Z-Wave, Thread or Bluetooth radio when it is
plugged in, says what it is, and tells Pulzar Cloud. Nothing has to be installed
first: the drivers and `pulzr-probe` are in every image.

## What happens when you plug one in

1. The kernel binds its driver: `cp210x`, `ch341`, `ftdi_sio`, `pl2303` or
   `cdc_acm` for a serial dongle (a `/dev/ttyUSB*` or `/dev/ttyACM*`), `btusb`
   for a Bluetooth one (an `hciN`).
2. Hotplug (`/etc/hotplug.d/tty`, `/etc/hotplug.d/bluetooth`) runs
   `pulzr-radios`, which waits two seconds for the burst of events a USB device
   makes and then runs `pulzr-probe` once.
3. `pulzr-probe` reads the device's identity from sysfs (USB vendor and product
   id, manufacturer, product and serial strings, physical port) and looks it up
   in its table of known adapters.
4. A known adapter is asked what firmware it runs, with only the probes its
   table entry allows. An adapter it cannot name is never written to.
5. When the list changed, the gateway sends its claim report at once and
   publishes its retained MQTT state again, both with `radios.detected`.
   The console shows a card on the gateway's page.

It also runs once at boot, for what was plugged in before power-on, and with
every six-hourly report.

## Why some adapters are not probed

The USB-to-serial chips inside most dongles (Silicon Labs CP210x, WCH CH340 and
CH9102, FTDI, Prolific PL2303) are also inside the RS-485 adapters used for
Modbus. A probe frame written to an RS-485 adapter goes out onto a live
fieldbus. So `pulzr-probe` names one of those chips only by a product string
that names a radio ("Home Assistant Connect ZBT-1", "SLZB-07", "ConBee III").
One with nothing more than the chip's own name is reported as an
**unidentified serial adapter** and left alone.

From the console, a person can then choose:

- **Identify**: probe it once, for every protocol, and keep what it answered.
- **This is a Modbus adapter**: hand it to Modbus. It is never probed again.

A port that any program has open (the Modbus daemon, a radio stack) is never
probed either.

## Known adapters

| Adapter | USB id | Carries |
|---|---|---|
| Home Assistant Connect ZBT-1 (SkyConnect) | `10c4:ea60` + product | Zigbee (EZSP), Thread |
| Home Assistant Connect ZBT-2 | `303a:4001` + product | Zigbee (EZSP), Thread |
| Home Assistant Connect ZWA-2 | `303a:4001` + product | Z-Wave |
| SONOFF ZBDongle-E | `1a86:55d4` + product | Zigbee (EZSP) |
| SONOFF ZBDongle-P | `10c4:ea60` + product | Zigbee (ZNP) |
| SMLIGHT SLZB-07 | `10c4:ea60` + product | Zigbee (EZSP), Thread |
| ConBee II | `1cf1:0030` | Zigbee (deCONZ) |
| ConBee III | `0403:6015` + product | Zigbee (deCONZ) |
| Nortek HUSBZB-1 | `10c4:8a2a` | Z-Wave (interface 0), Zigbee (interface 1) |
| Z-Wave USB controllers (Aeotec, Zooz 500 series, UZB) | `0658:0200` | Z-Wave |
| RTL8761B Bluetooth 5 adapters, ASUS USB-BT500 | `0bda:8771`, `0b05:190e` | Bluetooth |
| CSR8510 Bluetooth 4 adapters | `0a12:0001` | Bluetooth |

Coordinators on the LAN that serve their serial port over TCP (SMLIGHT SLZB-06,
UZG-01) are found by the mDNS answers `umdns` already collects on the LAN
ports.

The table is `crates/pulzr-probe/radios.json` in
[pulzr-edge](https://github.com/pulzar-net/pulzr-edge). To add an adapter, add
its product string there; `pulzr-probe check` refuses an entry that would
match a bare bridge chip.

## On the gateway

```sh
cat /var/run/pulzr-probe/radios.json     # what was found last
pulzr-radios scan                        # scan again now
pulzr-radios identify usb-10c4_ea60-0001 # a person's Identify
pulzr-radios assign usb-1a86_7523-1-1.3 modbus
logread -e radios
```

What a person decided is kept in `/etc/pulzr-probe/decisions.json`, across
upgrades.

Each radio's `id` stays the same when it is unplugged and plugged back: the USB
serial number when the adapter has one, otherwise the port it is in. `state` is
`free`, `unidentified`, `in-use`, `missing` or `unsupported` (a Thread radio,
reported but not run yet).

## Not yet

The probe frames come from the Zigbee and Z-Wave host stacks, which are not
built in yet. Until they are, a known adapter is reported as its table entry
says it ships, with `probe: unavailable`, and Identify answers that this
PulzrOS cannot probe radios. Running a Zigbee or Z-Wave network on a detected
radio comes with those stacks, as add-ons.
