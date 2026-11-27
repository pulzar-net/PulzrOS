---
title: "Quick start"
description: "From a blank Raspberry Pi to an adopted gateway."
---

From a blank Raspberry Pi to an adopted gateway. For a RAK or GL.iNet unit, see its [hardware page](/PulzrOS/hardware.html): those boot from soldered flash and install differently.

## 1. Download

Take the image for your board from the [latest release](https://github.com/pulzar-net/PulzrOS/releases):

| File | Use it for |
|---|---|
| `PulzrOS-<version>-<board>.img.xz` | writing a blank card |
| `PulzrOS-<version>-<board>.img.gz` | the same, for a writer that does not take xz |
| `PulzrOS-<version>-<board>-sysupgrade.img.gz` | upgrading a gateway that already runs PulzrOS |
| `*.pulzr.json` | the image's signature, checked by the gateway on upgrade |
| `sha256sums.txt` | checking the download |

## 2. Flash

Raspberry Pi Imager: **Choose OS > Use custom**, pick the `.img.xz`, write. Leave Imager's OS customization off; OpenWrt does not read it. Etcher, Rufus and `dd` work as well.

Or, from a clone of this repository:

```bash
./flash.sh --download rpi4
```

It refuses internal disks and asks you to type the disk identifier. See [Flashing](/PulzrOS/flashing.html).

## 3. Power on and open the console

Give it a minute on first boot. Then either:

- **Plug it into a network with internet.** It registers itself and appears in the pending list of the cloud it adopts into.
- **Plug a laptop straight into its ethernet port** and open `https://pulzr-<serial>.local`, or `https://192.168.61.1` when mDNS is blocked. Your laptop self-assigns `169.254.x.x` and says it has no internet; that is expected.

The initial password is on the card's boot partition as `pulzr-initial-password.txt`. The console makes you change it.

## 4. Adopt

The console, and the terminal UI on serial, HDMI or the USB cable, show a claim code. Scan it or enter it at `https://app.pulzr.net/adopt`, sign in and pick the organization. The gateway finishes adopting itself: it takes its MQTT credentials, enrols its management tunnel and turns off local password sign-in. See [One-touch provisioning](/PulzrOS/provisioning.html).

To adopt into your own cloud instead, build with your own endpoints: see [Building from source](/PulzrOS/building.html#adopting-into-your-own-cloud).

## Next

- [First boot and access](/PulzrOS/first-boot.html): every way to reach a gateway, including the setup AP.
- [Console guide](/PulzrOS/console.html): what each page does.
- [Networking](/PulzrOS/networking.html): WiFi uplinks, captive portals, cellular and failover.
