# Porting a board OpenWrt does not support

`rak7268c` and `rak7289cv2` have no upstream OpenWrt device profile — checked
against all 82 targets in 24.10, where the only Rakwireless entry is
`rakwireless_rak633`, an unrelated WiFi module. RAK's WisGateOS is an OpenWrt
fork whose board support they do not publish.

So a stock ImageBuilder has nothing to assemble and fails with
`Profile "rakwireless_rak7268c" does not exist!`. Those boards carry
`BOARD_STATUS="needs-device-support"`, which keeps them out of `--all` and out
of CI until this is done.

## Can we build support ourselves?

Yes. Not from the datasheet.

Published specs give the SoC and essentially nothing else. What a port needs —
the flash partition map, the GPIO assignments, the ethernet PHY wiring, which
pin resets the concentrator — is not in any specification, and one of those is
genuinely dangerous to guess:

> **Get the partition map wrong and the unit does not boot, and does not
> recover without a serial console and possibly a clip-on SPI flasher.**

It is also entirely avoidable. The vendor firmware is OpenWrt underneath, so a
running unit already knows all of it and will say so.

## The process

### 1. Harvest a stock unit

```bash
scripts/harvest-device.sh root@192.168.230.1 rak7268c
```

Everything it writes into `devices/<board>/` is fact read off the hardware
rather than inference. The prize is `devicetree.dts`, reconstructed from the
DTB the running kernel actually booted with.

> Do this **before** flashing anything. A unit running ParkezeOS cannot tell
> you what the vendor's partition map was, and that is the moment you need it.

### 2. Read the layout

`mtd` and `devicetree.dts` must agree. A typical MT7628 gateway looks like
u-boot / u-boot-env / factory (WiFi calibration and MACs) / firmware, and the
`factory` partition matters: it holds per-unit radio calibration that is not
reproducible if overwritten.

### 3. Write the OpenWrt device

This is buildroot work, not ImageBuilder — ImageBuilder assembles existing
devices and cannot add one. In an OpenWrt source tree:

- `target/linux/ramips/dts/mt7628an_rakwireless_rak7268c.dts`, derived from the
  harvested tree. Vendor trees carry out-of-tree bindings and have to be
  rewritten against upstream ones, but every address in them is real.
- a device recipe in `target/linux/ramips/image/mt76x8.mk`, giving
  `DEVICE_VENDOR`, `DEVICE_MODEL`, `SUPPORTED_DEVICES` and the image build.

### 4. Prove it without bricking anything

In order, and do not skip ahead:

1. Boot the new kernel over **TFTP from U-Boot**. Nothing is written to flash,
   so a wrong tree costs a power cycle.
2. Check `dmesg` and `/proc/mtd` against the harvest.
3. Only then write to flash — and have serial console access on the bench
   before you do.

### 5. Bring it home

Set `BOARD_STATUS="supported"`, point `OPENWRT_PROFILE` at the real profile
name, and fill in the values the harvest revealed: `PARKEZE_LED_*`,
`PARKEZE_SX130X_RESET_GPIO`, `PARKEZE_CONCENTRATOR_SLOTS`, `PARKEZE_GPS_DEV`.

`build.sh` will also need a buildroot path for these boards, since an
ImageBuilder cannot build a device that is not in the release. That is not
written yet — there is no point until a device exists to build.

## Upstream it

Once it boots, send the DTS and the image recipe to OpenWrt. Carrying device
support as a local patch means rebasing it onto every OpenWrt release forever;
upstream means the next release just has it, and `BOARD_STATUS` goes back to
`supported` with an ImageBuilder build like every other board.

## What is known today

Written from published specifications and **not verified against hardware**.
Every line is a hypothesis until the harvest confirms it.

| | RAK7268C | RAK7289CV2 |
|---|---|---|
| SoC | MediaTek MT7628 (assumed) | MediaTek MT7628 (assumed) |
| Concentrator | 1 × SX1302, 8 channels | 2 × SX1302, 16 channels |
| Cellular | yes (the "C") | yes |
| GNSS | integrated, node unknown | integrated, node unknown |
| Flash layout | **unknown — harvest it** | **unknown — harvest it** |
| GPIO / LED map | **unknown — harvest it** | **unknown — harvest it** |
