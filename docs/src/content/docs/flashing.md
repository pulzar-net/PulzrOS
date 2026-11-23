---
title: "Flashing a gateway"
description: "The images CI builds are raw disk images, so every SD writer takes them directly: Raspberry Pi Imager, balenaEtcher, Rufus, dd."
---

## Raspberry Pi — use whatever you already use

The images CI builds are **raw disk images**, so every SD writer takes them
directly: Raspberry Pi Imager, balenaEtcher, Rufus, `dd`. Nothing special.

> **Not an ISO.** An ISO is an optical-disc filesystem with no partition table
> and a Pi will not boot one. If a tool asks for an ISO it is the wrong tool
> for an SD card. What you want is the `.img.gz` or `.img.xz`.

### Raspberry Pi Imager

Download the image, then **Choose OS → Use custom** and pick the `.img.xz`.
Imager decompresses it for you; there is no need to unzip anything first.

```bash
gh run download --repo Pulzr/PulzrOS -n pulzros-rpi4
```

or grab the artifact from the Actions run in the browser.

Leave Imager's OS customization alone — the gear icon that offers to preset a
hostname, WiFi and SSH keys. It writes a Raspberry Pi OS-shaped config that
OpenWrt does not read, so nothing you set there applies and the image looks
broken. PulzrOS configures itself on first boot instead.

### Just download a file

From a CI artifact — `gh run download -n pulzros-rpi4`, or the Actions run
in the browser — or from a tagged release if one has been cut:

| File | For |
|---|---|
| `PulzrOS-<version>-rpi4.img.xz` | writing to a blank card. Smaller download. |
| `PulzrOS-<version>-rpi4.img.gz` | the same image, for a tool that dislikes xz. |
| `PulzrOS-<version>-rpi4-sysupgrade.img.gz` | **upgrading** a gateway already running PulzrOS, from its console. Not for a blank card. |
| `sha256sums.txt` | verify before writing. |

Open the `.img.xz` in Etcher or Imager's *Use custom* and write it. No need to
decompress first — both handle it.

### Or the script in this repo

```bash
./flash.sh --download rpi4     # fetch the latest CI image and write it
```

Worth it when you are flashing a lot of cards, because it picks the right
image, refuses internal disks, and never guesses the target.

If you have built locally, drop `--download`:

```bash
./build.sh rpi4                # produces out/rpi4/*.img.gz
./flash.sh rpi4                # pick a card interactively
./flash.sh rpi4 /dev/disk4     # or name it
./flash.sh --list-disks        # just show me what is plugged in
```

macOS and Linux. Needs `sudo` for the write itself and `gh` for `--download`.

### The safety rules

`dd` onto the wrong device takes a laptop's boot drive with it and there is no
undo, so:

- **Internal disks are refused**, not warned about. There is no flag to
  override it, because "I'm sure" is what people say right before this.
- **An external, non-removable disk needs `ALLOW_FIXED=1`.** That is a USB SSD
  or a backup drive — plausible to want, easy to hit by accident.
- **The target is never guessed.** Even with exactly one card inserted, it is
  shown and confirmed. "The only card plugged in" and "the card you meant" are
  not the same claim.
- **Confirmation is typing the disk identifier**, not pressing `y`. A reflex
  "y" is precisely what you produce when you have done this eleven times in an
  afternoon.

### Which image

ImageBuilder produces four per board; releases only publish the two that
anybody wants, renamed. For the record, the four are:

| | what it is |
|---|---|
| `squashfs-factory` | **the default.** Read-only rootfs plus a writeable overlay — the OpenWrt layout that failsafe mode and `jffs2reset` need. The reset button's factory-reset path depends on it. |
| `squashfs-sysupgrade` | for upgrading a gateway already running PulzrOS, from its own console. Not for a blank card. |
| `ext4-factory` | writable rootfs, no overlay. A factory reset has nothing to discard. Only for development. |
| `ext4-sysupgrade` | as above, for upgrades. |

## First boot

A minute or two while the gateway generates its identity, its console
certificate and its one-time password.

Most of the time nobody connects to it at all: plugged into anything with a
route out, it registers itself with Pulzr Cloud and appears in the pending list
there, where the installer adopts it by matching the EUI on the label. The ways
below are for when that has not happened.

| | |
|---|---|
| **Password** | On the boot partition as `pulzr-initial-password.txt` — the card mounts on any laptop. Or set your own before first boot by writing `pulzr-password.txt` there; it is applied and then deleted. |
| **Ethernet** | `https://pulzr-<serial>.local/`, or `https://192.168.61.1/` if mDNS is blocked. The gateway never hands out an address — your laptop will self-assign `169.254.x.x` and say it has no internet, which is expected. See [`access.md`](/PulzrOS/access.html). |
| **WiFi** | off by default. `pulzr_<mac>`, open while the gateway is unadopted, once somebody enables it from the console or Pulzr Cloud. |
| **Serial** | 115200 8N1 on the GPIO header. The banner prints the console address and the initial password. |

All three show the same claim code. Scan it or enter it at
`https://app.pulzr.net/adopt`, pick the organization, and the gateway finishes
adopting itself — see [`provisioning.md`](/PulzrOS/provisioning.html).

The console will not let you past the initial password without changing it.

## RAK WisGate — not yet

`flash.sh` refuses these, and says so:

```
rak7268c does not install from an SD card (BOARD_INSTALL=sysupgrade).
```

They boot from soldered flash rather than removable media, and OpenWrt has no
device profile for them, so there is no image to write in the first place. See
a board folder like `boards/rakwireless/rak7268cv2/openwrt/` ([`boards.md`](/PulzrOS/boards.html)).

When there is one, it will be installed through the vendor's upgrade path or
from U-Boot over TFTP — not by writing a whole-disk image, which is why
`BOARD_INSTALL` exists rather than `flash.sh` guessing from the file extension.


## Re-flashing a card that has run PulzrOS before

It works, and it gives you a genuinely clean device. That was not always true.

ImageBuilder truncates its `.img` the moment the squashfs ends — the file was
~90MB while its own partition table declared a 176MB layout. Everything past
that point is where OpenWrt keeps `rootfs_data`, the overlay that holds all
device configuration, so writing the image left the previous overlay completely
untouched.

The symptom was a flash that appeared to do nothing. The device booted the new
squashfs — new packages, new scripts, new everything in `/rom` — while wearing
the old `/etc/config`, the old identity and the old credentials. Worse,
`/etc/uci-defaults` was still marked as already-run from the previous boot, so
none of the new image's first-boot scripts executed. Diagnosing it meant
noticing a UCI key on the device that no current source file writes.

`scripts/package-images.sh` now pads the image out to the end of the last
partition before compressing, so the write covers the overlay and OpenWrt
reformats it on boot. It works for every writer — Pi Imager, Etcher, Rufus,
`dd`, `flash.sh` — rather than only for ours, and costs about 100KB of download
because a long run of zeros is what compression handles best.

If you have a device already in this state, you do not need to re-flash it:

```
firstboot -y && reboot
```

That wipes the overlay and lets the installed image's uci-defaults run as they
would have on a first boot.


## Upgrading a running gateway

### Where the image waits

An upgrade from the console or from Pulzr Cloud is written somewhere before
it is checked and flashed: on the SD card when the gateway has one; else in
RAM, when it fits with 16 MB to spare; else on the gateway's own flash (the
overlay), when that has room with 8 MB to spare. sysupgrade overwrites the
overlay, so an image checked there is not flashed from there:
`pulzr-firmware handoff` stops the services the upgrade would stop anyway,
moves the image into RAM and only then runs sysupgrade. If even then the
memory is not there, it starts the services again and flashes nothing, and
the gateway's firmware status says why (`state` failed, with a `reason`). A
GL-SFT1200 with no card (about 23 MB of RAM available against an 18.5 MB
image) upgrades this way.

### By hand

Root over SSH takes the fleet key or a Pulzr Cloud certificate, or on a
development image a key in `boards/common/ssh/dev/`; root has no password
([`auth.md`](/PulzrOS/auth.html), "Who gets root"). Anywhere else, upgrade from the
console or from Pulzr Cloud.

```
scp PulzrOS-<ver>-<board>-sysupgrade.img.gz root@<gateway>:/tmp/fw.img.gz
ssh root@<gateway> 'sha256sum /tmp/fw.img.gz'      # check it against the .sha256
ssh root@<gateway> 'sysupgrade -n /tmp/fw.img.gz'
```

**`sysupgrade -n` does not reset the overlay on bcm27xx.** Observed three
times on a Pi 3: the new squashfs lands correctly in `/rom`, but
`/overlay/upper` survives the upgrade, so any file the previous boot had
written keeps masking the new one underneath it. The gateway then runs new
code with old configuration, which mostly works — and is exactly the kind of
mostly that hides a problem. In one case `/etc/pulzr/board.conf` reported
the previous build's commit while `/rom` held the new one.

So follow an upgrade with:

```
ssh root@<gateway> 'firstboot -y && reboot'
```

That is what makes the new image's uci-defaults run. Confirm it took by
checking that the initial password changed: it is regenerated on a genuine
first boot, so an unchanged one means the overlay is still there.

The root cause has not been chased down. bcm27xx's sysupgrade writes the boot
and root partitions and leaves the `rootfs_data` area alone, and `-n` does not
appear to reach it on this target — but that is inference, not something that
has been read in the platform code.
