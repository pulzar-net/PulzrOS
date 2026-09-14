# Flashing a gateway

## Raspberry Pi — an SD card

```bash
./flash.sh --download rpi4     # fetch the latest CI image and write it
```

That is the whole thing. It picks the right image, shows you the removable
disks, refuses the internal one, and asks you to type the disk identifier
before it writes.

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

Four are built per board. `flash.sh` picks **squashfs-factory** and that is
almost always what you want:

| | what it is |
|---|---|
| `squashfs-factory` | **the default.** Read-only rootfs plus a writeable overlay — the OpenWrt layout that failsafe mode and `jffs2reset` need. The reset button's factory-reset path depends on it. |
| `squashfs-sysupgrade` | for upgrading a gateway already running ParkezeOS, from its own console. Not for a blank card. |
| `ext4-factory` | writable rootfs, no overlay. A factory reset has nothing to discard. Only for development. |
| `ext4-sysupgrade` | as above, for upgrades. |

## First boot

A minute or two while the gateway generates its identity, its console
certificate and its one-time password. Then it is reachable three ways:

| | |
|---|---|
| **Ethernet** | `https://192.168.61.1/`. The port hands out an address — but only if it is not plugged into a network that already has a DHCP server; see [`access.md`](access.md). |
| **WiFi** | join `parkeze_<mac>`. Open while the gateway is unadopted, because it holds nothing worth protecting yet. |
| **Serial** | 115200 8N1 on the GPIO header. The banner prints the console address and the initial password. |

All three show the same claim code. Scan it or enter it at
`https://parkeze.net/adopt`, pick the organisation, and the gateway finishes
adopting itself — see [`provisioning.md`](provisioning.md).

The console will not let you past the initial password without changing it.

## RAK WisGate — not yet

`flash.sh` refuses these, and says so:

```
rak7268c does not install from an SD card (BOARD_INSTALL=sysupgrade).
```

They boot from soldered flash rather than removable media, and OpenWrt has no
device profile for them, so there is no image to write in the first place. See
[`../devices/README.md`](../devices/README.md).

When there is one, it will be installed through the vendor's upgrade path or
from U-Boot over TFTP — not by writing a whole-disk image, which is why
`BOARD_INSTALL` exists rather than `flash.sh` guessing from the file extension.
