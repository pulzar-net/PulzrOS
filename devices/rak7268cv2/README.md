# RAK7268CV2 — harvest

Read off a stock unit over the serial console (57600 8N1, root/root) on
2026-09-16. Every other file in this directory is raw command output;
`devicetree.dts` is decompiled from the running kernel's `/sys/firmware/fdt`.

## Hardware

| | |
|---|---|
| Module | RAK636 (`rakwireless,rak636`) |
| SoC | MediaTek MT7628AN ver 1 eco 2, ramips/mt76x8, mipsel_24kc |
| Flash | Winbond W25Q256FV, 32MB SPI NOR, CS0 |
| RAM | 128MB |
| Concentrator | SX1302 + 2×SX1250, SPI CS1 @ 40MHz, reset GPIO 11 (active high pulse), no power-enable |
| Cellular | Quectel EG95 (2c7c:0195), USB, option + qmi_wwan; standby/power on GPIO 41/42 |
| GNSS | none |
| Ethernet | one port, switch port 0 (WAN, eth0.2); port 1 is LAN |
| WiFi | MT7628 internal (vendor runs the proprietary `ra0` driver; upstream is mt7603) |
| Console | ttyS0, 57600 |

## GPIO

| GPIO | Use | Polarity |
|---|---|---|
| 11 | SX1302 reset | high = reset |
| 14 | LED `rak:green:lora1` | active low |
| 15 | LED `rak:green:lora` | active low |
| 18 | key `dying-gasp` (input) | |
| 38 | key `reset` (KEY_RESTART) | active low |
| 41, 42 | EG95 standby / power (`/usr/bin/quectel-reset`) | |
| 43 | LED `rak:green:eth` | active low |
| 44 | LED `mediatek:orange:wifi` | active low |

## Flash map

Agrees between `/proc/mtd` and the DTS.

| Offset | Size | Name | Notes |
|---|---|---|---|
| 0x000000 | 0x30000 | u-boot | read-only; Ralink U-Boot |
| 0x030000 | 0x10000 | u-boot-env | |
| 0x040000 | 0xe000 | factory | WiFi calibration + MACs. **Irreplaceable.** |
| 0x04e000 | 0x2000 | pst-data | vendor persistent data (unit identity). **Keep.** |
| 0x050000 | 0x1fb0000 | firmware | `denx,uimage`: kernel then squashfs, standard OpenWrt split |

`backup/` holds md5-verified dumps of the first four, taken before anything
was flashed. It is gitignored: these are per-unit, and a copy only helps the
unit it came from. **Keep it somewhere safe.** To put one back from a running
OpenWrt: `mtd -r write mtd2-factory.bin factory` (the partition must not be
read-only in that image's DTS).

## Recovery: back to stock

Ralink U-Boot 4.3.0.0 (2018). No web failsafe, but a TFTP menu; `bootdelay=5`.
The menu below is copied from a real boot (`uboot-boot`).

1. Get the stock image: RAK's download page for RAK7268V2/RAK7268CV2,
   WisGateOS 2 (`.bin`). This unit ran 2.2.16.
2. Wire the Mac to the gateway's ethernet port. Give the Mac `10.10.10.3/24`
   (U-Boot's `serverip`; the board uses `ipaddr=10.10.10.123`).
3. Serve the image over TFTP:

   ```bash
   sudo cp firmware.bin /private/tftpboot/ && sudo launchctl load -F /System/Library/LaunchDaemons/tftp.plist
   ```

4. Open the console, power-cycle, and press the option number during the 5s
   countdown.
   The menu:

   ```
   1: Load system code to SDRAM via TFTP.            <- boot an image, write nothing
   2: Load system code then write to Flash via TFTP. <- recovery / install
   3: Boot system code via Flash (default).
   4: Boot U-Boot command line
   7: Load Boot Loader code then write to Flash via Serial.
   9: Load Boot Loader code then write to Flash via TFTP.
   ```

   Pick **2**, confirm the IPs and filename. It writes to 0x50000, i.e. the
   `firmware` partition only — u-boot, factory and pst-data are untouched.

**Never pick 7 or 9.** They overwrite the bootloader, and a bad one needs an
SPI clip to recover.

Unverified: that RAK's `.bin` is a plain uImage+squashfs that option 2 takes
as-is. The stock sysupgrade path (`sysupgrade -n firmware.bin` from a running
WisGateOS) is the safer first try; U-Boot TFTP is the path for a unit that no
longer boots.

## Testing ParkezeOS without flashing

Menu option **1** loads an initramfs image into RAM and boots it. Nothing is
written, so a wrong DTS costs a power cycle. This is step 4.1 of
[`../README.md`](../README.md): build the `initramfs-kernel.bin` first, and
only use option 2 once `dmesg` and `/proc/mtd` match this harvest.
