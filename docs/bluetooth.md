# Bluetooth

A PulzarOS gateway can scan for parking beacons beside its LoRaWAN radio, so
one gateway serves both kinds of sensor. It is off on every gateway until it
is turned on, from the gateway's page in Pulzar Cloud (Settings → General →
Bluetooth) or from the console's Bluetooth page. Both write
`pulzr.ble.enabled`.

## What it sends

`pulzr-ble` scans passively and, every `pulzr.ble.interval` seconds,
publishes the latest advertisement of each beacon whose MAC starts with one of
`pulzr.ble.oui` (KKM's `BC5729` by default) on
`parkeze/gateway/<eui>/ble/up`, with the gateway's own broker identity.
Pulzar Cloud decodes them with the device type's codec, exactly as it decodes
a KGateway's raw frames, so a new beacon model is a codec there and never a
firmware change here.

## Which program scans

`pulzr.ble.backend` picks it, and the `pulzr-ble` service is the only one that
starts either, so they never hold the radio together:

| backend | program | sends |
|---------|---------|-------|
| `pulzr-ble` (default) | the shell scanner above (hcitool, hcidump) | one `ble/up` batch per interval, on the gateway's topic |
| `pulzr-edge` | `pulzr-edge ble`, from the pulzr-edge add-on | Pulzar protocol v1: each beacon its own device `ble:<EUI-64>`, one `up` per interval; GATT and advertising intents |

Both read the same `pulzr.ble` settings (`oui` becomes pulzr-edge's `admit`,
empty meaning every device; `min_rssi`; `interval`). With `pulzr-edge`, the
service attaches the chip as before, takes `hci0` down and execs
`pulzr-edge ble` with a config generated at every start
(`/usr/libexec/pulzr/edge-config`, which also writes the Modbus daemon's).
Without the add-on installed it logs that and retries every minute.

Switching a gateway is `uci set pulzr.ble.backend=pulzr-edge`, `uci commit
pulzr` and `/etc/init.d/pulzr-ble restart`. A gateway whose beacons are live
moves only on the owner's go-ahead: the platform then hears them as protocol
v1 devices instead of the `ble/up` batches. The console's beacon count comes
from the shell scanner and is empty under `pulzr-edge`.

`scripts/test-ble-backend.sh` checks the generated config against what
pulzr-edge's `[ble]` accepts.

## On a Pi

OpenWrt's `distroconfig.txt` switches the chip off on every Pi 3 and 4
(`disable-bt`) to give the PL011 to the header pins, which PulzarOS uses for
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
`BT_ON` the chip stays in reset and `hciattach` times out.

Proven on a Pi 3 on 12 October 2026: attached on the mini UART,
heard 27 devices in 15 seconds, and Pulzar Cloud stored what it sent. The Pi 4
uses the same path and has not been tried. The Pi 5's chip is on a UART of its
own that the kernel claims for a driver this OpenWrt does not build, so it
reports no Bluetooth; a USB dongle works on any board.
