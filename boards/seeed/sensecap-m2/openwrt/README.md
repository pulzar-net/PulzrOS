# sensecap-m2: OpenWrt device support

OpenWrt device support for the Seeed SenseCAP M2 Multi-Platform LoRaWAN
gateway (its SenseCAP WM7628N module), built into its ImageBuilder by scripts/device-imagebuilder.sh.
OpenWrt 25.12.6, `ramips/mt76x8`, profile `sensecap_wm7628n`.


## The hardware

| | |
|---|---|
| SoC | MediaTek MT7628AN |
| Flash | 32MB SPI NOR: `u-boot` 192k, `u-boot-env` 64k, `factory` 64k (radio calibration at 0x0, wired MAC at 0x2e), `firmware` the rest |
| Storage | SD card |
| Concentrator | Seeed WM1302 (SX1302 + SX1250) on SPI chip select 1, `/dev/spidev0.1`. Reset GPIO 14, power-enable GPIO 3, SX1261 reset GPIO 15, driven by the packet forwarder |
| LEDs | `green:wlan` (GPIO 44), `green:wan` (42), `green:lora` (36) |
| Button | reset (GPIO 40) |

## Where it comes from

The device tree is ChirpStack Gateway OS's for the M2
(`conf/seeed_sensecap_m2/patches/add_sensecap_wm7628n_device.diff`), licensed
`GPL-2.0-or-later OR MIT` in its own header, ported to OpenWrt 25.12: MAC
addresses and the radio calibration come from nvmem cells, and the concentrator
is declared `semtech,sx1301` so spidev binds it by name. The concentrator's
lines are from ChirpStack's OpenWrt feed (MIT).

Not yet booted on a unit: check `/sys/kernel/debug/gpio`, `/proc/mtd` and
`ls /dev/spidev*` on the first one before sending it upstream.

## Installing

The compatible is `sensecap,wm7628n`, the board name of Seeed's firmware and of
ChirpStack Gateway OS, so the sysupgrade image is accepted from either.


## Licence

GPL-2.0, as OpenWrt. The device tree is `GPL-2.0-or-later OR MIT`.
