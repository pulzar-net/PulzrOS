# Flashing a gateway

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
gh run download --repo parkezesolutions/ParkezeOS -n parkezeos-rpi4
```

or grab the artifact from the Actions run in the browser.

Leave Imager's OS customisation alone — the gear icon that offers to preset a
hostname, WiFi and SSH keys. It writes a Raspberry Pi OS-shaped config that
OpenWrt does not read, so nothing you set there applies and the image looks
broken. ParkezeOS configures itself on first boot instead.

<details>
<summary>Why ParkezeOS is not in Imager's OS menu</summary>

Imager can be pointed at a custom OS list, which would put ParkezeOS in the
menu next to Raspberry Pi OS and refuse to write a Pi 5 image to a Pi 3.

It fetches that list, and every image in it, **with no credentials**. This
repository is private and so are its release assets, so Imager gets a 404 and
shows an empty menu with nothing on screen explaining why. Making it work means
publishing the images somewhere anonymously reachable — which is a decision
about distribution, not a build setting.

The build supports it when that decision is made. Set a base URL and CI emits
`os_list.json` alongside the images:

```
PARKEZE_IMAGE_BASE_URL=https://downloads.parkeze.net/os/v0.1.0
```

With it unset — the default — no OS list is produced, because a list of URLs
that 404 is worse than no list. The images themselves carry no secrets: a
gateway holds nothing until it is adopted, and the only key in the image is the
fleet recovery **public** key. So publishing them is a business decision rather
than a security one.

</details>

### Just download a file

From a CI artifact — `gh run download -n parkezeos-rpi4`, or the Actions run
in the browser — or from a tagged release if one has been cut:

| File | For |
|---|---|
| `ParkezeOS-<version>-rpi4.img.xz` | writing to a blank card. Smaller download. |
| `ParkezeOS-<version>-rpi4.img.gz` | the same image, for a tool that dislikes xz. |
| `ParkezeOS-<version>-rpi4-sysupgrade.img.gz` | **upgrading** a gateway already running ParkezeOS, from its console. Not for a blank card. |
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
