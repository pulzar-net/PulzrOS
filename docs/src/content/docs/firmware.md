---
title: "Firmware updates and signing"
description: "Settings and the gateway's identity are kept across an upgrade (/lib/upgrade/keep.d/)."
---

## Updating a gateway

| From | How |
|---|---|
| The cloud | pick a release on the gateway's page; the gateway downloads and checks it |
| The console | **System > Maintenance > Firmware**, upload the image |
| A shell | `sysupgrade` with the `-sysupgrade` image (Pi) or the `.bin` (RAK, GL.iNet) |

Settings and the gateway's identity are kept across an upgrade (`/lib/upgrade/keep.d/`). Add-ons are restored after the first healthy boot of the new version.

By hand, as root:

```sh
scp PulzrOS-<ver>-<board>-sysupgrade.img.gz root@<gateway>:/tmp/fw.img.gz
ssh root@<gateway> 'sha256sum /tmp/fw.img.gz'
ssh root@<gateway> 'sysupgrade -n /tmp/fw.img.gz'
```

On a Pi, `sysupgrade -n` can leave the old overlay in place. Follow it with `firstboot -y && reboot`, and check that the initial password changed. See [Flashing](/PulzrOS/flashing.html#upgrading-a-running-gateway).

## What the gateway checks

Before an image is written over the running system:

1. **The board.** Every OpenWrt sysupgrade image ends with a metadata block listing the boards it supports; this board must be in it. That also rejects a truncated upload, which has no block.
2. **The signature.** Each release image has a `<image>.pulzr.json` beside it: a manifest (the image's SHA-256, version and build time) and an Ed25519 signature over it. The gateway verifies the signature against `PULZR_FIRMWARE_PUBKEY`, built into the image, and the digest against the file. An image without a valid signature is refused.
3. **Room.** The image sits in RAM, or on the SD card when there is one, with enough left for the gateway to keep running.

Only a development image (`PULZR_DEV=1`) accepts an unsigned image.

## Rollback

`pulzr-firmware` keeps a journal of each upgrade: the version it came from, who asked, and whether the new boot was confirmed healthy. Each upgrade stashes the image it installs on the SD card, so the next upgrade can roll back to it. The first upgrade under this scheme has no predecessor stashed and cannot roll back; `pulzr-firmware status` says so. A gateway with no card keeps the journal and cannot roll back.

```sh
pulzr-firmware status
```

## How releases are signed

The `release` job in [`.github/workflows/build.yml`](https://github.com/pulzar-net/PulzrOS/blob/main/.github/workflows/build.yml) runs on a version tag. For each image it writes the manifest, signs it with the `FIRMWARE_SIGNING_KEY` secret, verifies the signature against the public half on the spot, and attaches `<image>.pulzr.json` to the release. A release without the key fails rather than publishing images no gateway will install.

A tag must match `VERSION`: a gateway reports `VERSION`, and the cloud offers a release whose version is newer. CI refuses a mismatch before building anything.

Versions are SemVer. A release candidate is dotted (`v0.4.0-rc.9`, then `v0.4.0-rc.10`), so its number compares as a number, and leads to that version's release (`v0.4.0`). Tags up to `v0.4.0-rc8` were undotted and still order: `rc8` reads as `rc.8`. Tags with a hyphen are pre-releases: installable by tag, never offered as the latest.

Cut a release on the commit that sets `VERSION` to it, as an annotated tag whose message is the release notes: `git tag -a v0.4.0-rc.9 --cleanup=whitespace -F notes.md`. Without `--cleanup=whitespace`, git drops Markdown headings as comments.

The signed manifest beside each image names the release twice: `tag`, as tagged, and `version`, with a dotted release candidate written undotted (`v0.4.0-rc9`). Gateways up to `v0.4.0-rc8` order by `version`, and read `rc.9` as older than their own `rc8`, so they would refuse it as a downgrade. Newer gateways read both spellings as one release, and find the release's add-ons by `tag`.

## Your own keys

An image trusts the keys it was built with. For your own fleet, generate an Ed25519 pair, keep the private half in your CI secrets, and build with the public half:

```bash
openssl genpkey -algorithm ed25519 -out firmware.key
openssl pkey -in firmware.key -pubout -out firmware.pub
PULZR_FIRMWARE_PUBKEY=firmware.pub ./build.sh rpi4
```

See [Building from source](/PulzrOS/building.html#keys).

## Add-ons

Add-ons are signed separately, as an apk repository per release and architecture. See [Add-ons](/PulzrOS/addons.html).
