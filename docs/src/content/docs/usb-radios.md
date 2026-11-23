---
title: "Plugged-in radios"
description: "A PulzrOS gateway notices a Zigbee, Z-Wave, Thread or Bluetooth radio when it is plugged in, says what it is, and tells Pulzr Cloud."
---

A PulzrOS gateway notices a Zigbee, Z-Wave, Thread or Bluetooth radio when it is
plugged in, says what it is, and tells Pulzr Cloud. Nothing has to be installed
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
5. When the list changed, the gateway sends it to Pulzr Cloud at once, on
   its own (`pulzr-claim radios`, a few hundred bytes), and publishes its
   retained MQTT state again. The gateway's page shows the card within
   seconds.

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
| Nordic nRF52840 Dongle with OpenThread's RCP | `1915:cafe` + product | Thread |
| ConBee II | `1cf1:0030` | Zigbee (deCONZ) |
| ConBee III | `0403:6015` + product | Zigbee (deCONZ) |
| Nortek HUSBZB-1 | `10c4:8a2a` | Z-Wave (interface 0), Zigbee (interface 1) |
| Zooz ZST10 700 | `10c4:ea60` + product | Z-Wave |
| Z-Wave USB controllers (Aeotec, Zooz 500 series, UZB) | `0658:0200` | Z-Wave |
| RTL8761B Bluetooth 5 adapters, ASUS USB-BT500 | `0bda:8771`, `0b05:190e` | Bluetooth |
| CSR8510 Bluetooth 4 adapters | `0a12:0001` | Bluetooth |
| LoRaWAN concentrators on Semtech's USB reference (RAK5146 USB) | `0483:5740` + product | LoRaWAN |

Coordinators on the LAN that serve their serial port over TCP (SMLIGHT SLZB-06,
UZG-01) are found by the mDNS answers `umdns` already collects on the LAN
ports.

The table is `crates/pulzr-probe/radios.json` in
[pulzr-edge](https://github.com/pulzar-net/pulzr-edge). To add an adapter, add
its product string there; `pulzr-probe check` refuses an entry that would
match a bare bridge chip.

## Cellular modems

A cellular modem is not a radio pulzr-probe names: it is listed beside them,
as `modems`, by `/usr/libexec/pulzr/usb-modems` (pulzr-probe's package, every
image), so a gateway can say it has one before anything on it can drive one.
That is what Pulzr Net offers the Cellular add-on on; see
[backhaul.md](/PulzrOS/backhaul.html), "Cellular is an add-on".

It reads the USB descriptors sysfs has for every device, no driver needed,
and a USB hotplug hook (`/etc/hotplug.d/usb/40-pulzr-probe`) scans when a
device is plugged in or pulled out:

| `kind` | Device |
|---|---|
| `mbim` | an MBIM interface (02/0e), from any maker |
| `vendor` | vendor-specific interfaces (QMI, AT ports) from a modem maker |
| `acm` | a CDC-ACM AT port from a modem maker |
| `mode-switch` | mass storage from a maker whose dongles start as a CD-ROM |
| `ethernet` | RNDIS, or CDC-ECM/NCM from a modem or phone maker: a HiLink dongle, Android tethering |
| `iphone` | an iPhone, or an iPad with cellular |

Vendor-specific and ACM interfaces are also an FTDI's, a CH341's, a ConBee's
and a u-blox GNSS receiver's, and ECM is a Realtek Ethernet adapter's, so
those count only from a modem or phone maker (the tables at the top of
`usb-modems`). A modem it misses can still have the add-on installed from
the Add-ons list; one it lists wrongly only offers an install nobody needs.

```json
{"id":"usb-2c7c_0125-1-1.2","port":"1-1.2","label":"Quectel EC25","kind":"vendor",
 "driver":null,"usb":{"vid":"2c7c","pid":"0125","manufacturer":"Quectel","product":"EC25","serial":""}}
```

`driver` is the first driver bound to one of its interfaces: null until the
add-on's kmods are loaded.

## On the gateway

```sh
pulzr-radios list                        # the radios and modems found last
cat /var/run/pulzr-probe/radios.json     # pulzr-probe's own report
pulzr-radios scan                        # scan again now
pulzr-radios identify usb-10c4_ea60-0001 # a person's Identify
pulzr-radios assign usb-1a86_7523-1-1.3 modbus
logread -e radios
```

What a person decided is kept in `/etc/pulzr-probe/decisions.json`, across
upgrades.

Each radio's `id` stays the same when it is unplugged and plugged back: the USB
serial number when the adapter has one, otherwise the port it is in. `state` is
`free`, `unidentified`, `in-use`, `missing` or `unsupported`. A Thread radio
is `free` until the pulzr-thread add-on runs a border router on it
([thread.md](/PulzrOS/thread.html)), then `in-use`.

## What a probe asks

Each probe is read-only, takes about three seconds at most, and closes the port
before it returns. Nothing it sends writes a radio's memory, forms a network or
resets a controller.

| Radio | Asked with | Reports |
|---|---|---|
| Zigbee, Silicon Labs (EZSP) | ASH reset, EZSP `version`, version info, EUI-64, manufacturer and board tokens | EmberZNet firmware, EZSP protocol version, board |
| Z-Wave | `GET_SERIAL_API_CAPABILITIES`, then controller version, id, init data, capabilities and RF region | Serial API firmware, chip series (500, 700, 800) |
| Thread (OpenThread RCP) | Spinel `NCP_VERSION` and `CAPS` | OpenThread firmware |
| LoRaWAN concentrator on USB | the reference MCU's `REQ_PING` | MCU firmware |
| LoRaWAN concentrator on SPI | one reset with the board's lines, the version register | SX1301, SX1302 or SX1303 |

The Zigbee and Z-Wave probes come from the host stacks
([zigbee-bridge](https://github.com/pulzar-net/zigbee-bridge),
[zwave-bridge](https://github.com/pulzar-net/zwave-bridge)); the Thread and
LoRaWAN ones are pulzr-probe's own.

## Concentrators

A LoRaWAN concentrator is offered the way a Zigbee stick is: pulzr-probe lists
it (`protocol: lorawan`), and Pulzar Net offers the pulzr-lorawan add-on
([concentrators.md](/PulzrOS/concentrators.html)). On USB it is named by its
table entry like any radio. On SPI, which has no hotplug and no discovery,
the boot scan alone reads the board's one slot (`PULZR_SPI_DEV`, with
`PULZR_SX130X_RESET_GPIO` and `PULZR_SX130X_POWER_EN_GPIO`, the lines the
board's most common HAT uses), and only on a kit board, whose slots are
`auto`; a board with fixed slots has the add-on in its image. A slot is
listed as `spi-spidev0.0` only when a real part answered; later scans keep
what the boot scan found and pulse nothing.

Once pulzr-lorawan is installed it owns its concentrators: every scan is told
so (`--claimed lorawan`), and a concentrator is named and never asked again,
because a probe in the middle of concentratord's own exchange would break it.
The add-on's own detection reads the same report for its USB slots and asks
pulzr-probe to read an SPI slot with the HAT profile somebody picked.

## Not yet

TI Z-Stack (ZNP) and ConBee (deCONZ) coordinators are named but not asked yet:
they are reported as their table entry says they ship, with
`probe: unavailable`. Running a Zigbee or Z-Wave network on a detected radio
comes with those stacks, as add-ons.
