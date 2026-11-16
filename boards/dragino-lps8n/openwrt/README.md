# dragino-lps8n: OpenWrt device support

OpenWrt device support for the Dragino LPS8N indoor LoRaWAN gateway, and the
ImageBuilders built with it. OpenWrt 25.12.6, `ath79/generic`, profile
`dragino_lps8n`. Upstream OpenWrt has the older LPS8 (AR9330), not the LPS8N.


## The hardware

| | |
|---|---|
| SoC | Atheros AR9331, 400 MHz MIPS 24Kc |
| Flash | 16MB SPI NOR: `u-boot` 256k, `firmware` 16000k, `config` 64k, `art` 64k (MACs at 0x0 and 0x6, Wi-Fi calibration at 0x1000) |
| Concentrator | Dragino PG1302 (SX1302 + SX1250) on bit-banged SPI: GPIO 18 MOSI, 20 MISO, 24 SCK, 19 chip select; `/dev/spidev1.0`. Reset on GPIO 23, driven by the packet forwarder |
| Temperature sensor | on bit-banged I2C, GPIO 7 SDA, 8 SCL |
| LEDs | `red:wlan` (GPIO 0), `dragino2:red:wan` (17), `dragino2:red:lan` (13), `dragino2:red:system` (28) |
| Buttons | WPS (GPIO 11), reset (GPIO 12) |

## Where it comes from

The device tree is ChirpStack Gateway OS's for the LPS8N
(`conf/dragino_lps8n/patches/add_dragino_lps8n_device.patch`), licensed
`GPL-2.0-or-later OR MIT` in its own header, ported to OpenWrt 25.12: the
concentrator is declared `semtech,sx1301` so spidev binds it by name without a
kernel patch, and Wi-Fi calibration comes from the device tree's nvmem cell, as
25.12 reads it, rather than a hotplug script. The reset line is concentratord's
default for a PG1302, which ChirpStack's own LPS8N configuration relies on.

Not yet booted on a unit: the first one through it should be checked against
`/sys/kernel/debug/gpio`, `/proc/mtd` and `ls /dev/spidev*` before it is sent
upstream.

## Installing

`SUPPORTED_DEVICES` includes `dragino2`, the board name Dragino's own firmware
reports, so the sysupgrade image is accepted from the stock web UI's firmware
upgrade or `sysupgrade -n` from its shell. Keep a copy of the stock firmware:
going back is the same path in reverse.


## Licence

GPL-2.0, as OpenWrt. The device tree is `GPL-2.0-or-later OR MIT`.
