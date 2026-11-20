---
title: "Bluetooth"
description: "Bluetooth is the pulzr-ble add-on (addons.md): installed on request from Pulzar Net, on the board's own radio or a USB dongle, and off until it is turned on, from the gateway's page in Pulzar Net..."
---

Bluetooth is the pulzr-ble add-on ([addons.md](/PulzrOS/addons.html)): installed on
request from Pulzar Net, on the board's own radio or a USB dongle, and off
until it is turned on, from the gateway's page in Pulzar Net or the console's
Bluetooth page, which is there while the add-on is installed. Both write
`pulzr.ble.enabled`.

## What it sends

The add-on runs `pulzr-edge-ble`, pulzr-edge built with its `ble` feature
alone. It scans passively and sends each beacon whose MAC starts with one of
`pulzr.ble.oui` (KKM's `BC5729` by default; empty sends every device) as its
own device, `ble:<EUI-64>`, in Pulzar protocol v1: at most one `up` per
beacon per `pulzr.ble.interval` seconds, none weaker than `pulzr.ble.min_rssi`,
on the gateway's own broker login. Pulzar Net decodes the advertising data
with the device type's codec, so a new beacon model is a codec there and never
a firmware change here. GATT reads and writes and advertising come as intents.

`pulzr-edge-ble` owns the whole controller over the HCI user channel. The
`pulzr-ble` service attaches the chip, takes `hci0` down and execs it with a
config generated at every start (`/usr/libexec/pulzr/edge-config`, in
pulzr-probe, which also writes the Modbus daemon's).
`scripts/test-ble-config.sh` checks that config against what pulzr-edge's
`[ble]` accepts.

Bluetooth is little-endian only (bt-hci), so there is no pulzr-ble for a
big-endian mips board.

## On a Pi

OpenWrt's `distroconfig.txt` switches the chip off on every Pi 3 and 4
(`disable-bt`) to give the PL011 to the header pins, which PulzrOS uses for
the console or GNSS. Turning Bluetooth on moves the chip to the mini UART
instead (`miniuart-bt`), so the header is unchanged:

| config.txt              | why                                                          |
|-------------------------|--------------------------------------------------------------|
| `dtoverlay=miniuart-bt` | the chip on the mini UART, the PL011 left on the header      |
| `dtparam=krnbt=off`     | the mini UART stays a tty; the kernel has no Broadcom driver |
| `core_freq=250` (Pi 3)  | a fixed clock, so the mini UART's baud rate does not drift   |
| `core_freq_min=500` (Pi 4) | the same, for the Pi 4's clock                            |

`pulzr-boot-config` adds these while Bluetooth is on and removes them when
it is off; the Pi firmware reads them only at boot, so turning it on the first
time needs one reboot, which both switches offer.

At start, `pulzr-ble` raises `BT_ON` (line 0 of the firmware's GPIO
expander) and attaches the chip with `hciattach … bcm43xx 460800`. Without
`BT_ON` the chip stays in reset and `hciattach` times out. `hciattach` is
bluez-utils, in every Pi image: an add-on brings only its own package.

Proven on a Pi 3 on 12 October 2026: attached on the mini UART,
heard 27 devices in 15 seconds, and Pulzar Cloud stored what it sent. The Pi 4
uses the same path and has not been tried. The Pi 5's chip is on a UART of its
own that the kernel claims for a driver this OpenWrt does not build, so it
reports no Bluetooth; a USB dongle works on any board.
