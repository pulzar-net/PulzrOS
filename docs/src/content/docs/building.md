---
title: "Building from source"
description: "PulzrOS is assembled with OpenWrt's ImageBuilder from a pinned release (OPENWRT_VERSION in boards/common/board.conf)."
---

PulzrOS is assembled with OpenWrt's ImageBuilder from a pinned release (`OPENWRT_VERSION` in `boards/common/board.conf`). Nothing is compiled from source for a supported board except the console and the LoRa packages.

## Requirements

- `node` 20 or newer, `curl`, `jq`, `zstd`, and GNU `tar` for byte-reproducible packages
- Linux for image assembly: the ImageBuilder is x86_64 binaries. On a Mac, `build.sh` runs that step in Docker.
- About 150 MB for the first ImageBuilder download, cached and checksum-verified

## Build

```bash
./build.sh --list          # boards that can be built
./build.sh rpi4            # one board
./build.sh --all           # every buildable board
```

`build.sh` builds the React console, stages the package feed, and assembles the image, in that order. Images land in `out/<board>/`. Each stage runs on its own too:

```bash
./build.sh --stage console
./build.sh --stage feed
./build.sh --stage image rpi4
./build.sh --stage addons
```

A board whose status is `needs-device-support` needs its ImageBuilder built from `boards/<board>/openwrt/` first (`scripts/device-imagebuilder.sh`): Linux and a couple of hours. CI does this once per change to those files.

## Development images

```bash
PULZR_DEV=1 ./build.sh rpi4
```

A root shell on the serial console, failsafe mode, and your public key from `boards/common/ssh/dev/` (ignored by git). The version ends in `-dev` and CI refuses to build one for release.

## Keys

Three public keys decide what an image trusts. None is secret.

| Variable | What it is | Without it |
|---|---|---|
| `PULZR_RECOVERY_PUBKEY` | Ed25519 key offline recovery is signed with | no offline adoption or recovery |
| `PULZR_FIRMWARE_PUBKEY` | Ed25519 key firmware is signed with | the gateway refuses to verify any image |
| `PULZR_SSH_CA_PUBKEY` | SSH user CA root accepts (default `boards/common/ssh/pulzr_user_ca.pub`) | root reached by the fleet key only |

`boards/common/ssh/fleet/pulzr-fleet.pub` goes into root's `authorized_keys`. The CA and fleet key in this tree are Pulzar's: **replace both with your own before building for your own fleet**, or build with `PULZR_OPS_KEYS=0` for no fleet key at all. See [Authentication and SSH](/PulzrOS/auth.html#the-keys-in-this-repo).

## Adopting into your own cloud

By default a gateway adopts into Pulzar Cloud at `https://app.pulzr.net`. To use your own, set `PULZR_NET_URL` and `PULZR_MQTT_HOST` in `boards/common/board.conf` to a server that implements the gateway API under `/api/v1/gateway-ops/`: claim registration and polling, adoption, reporting and WireGuard enrolment. [One-touch provisioning](/PulzrOS/provisioning.html) walks the protocol.

## Repository layout

```
boards/     one directory per board; common/ holds everything shared
console/    the React console, built to static files
feed/       the OpenWrt package feed (pulzr-*)
sdk/        what is built with the OpenWrt SDK: LoRa, busybox, pulzr-probe, pulzr-edge
scripts/    the feed and image tooling, the checks and the tests
docs/       this site
```

## CI

The hours-long builds run in `prebuilt.yml`: each SDK target's packages (`sdk/build.sh`, cached by `sdk/key`) and each device ImageBuilder (`scripts/device-imagebuilder.sh`, cached by its device key). Each is its own concurrency group that never cancels a running job, and saves its cache as soon as it is built. `build.yml` only restores them. Each board's image job restores its own target's SDK packages and ImageBuilder, stages its own architecture's packages, and assembles, so no board waits on another target. A board whose build is not cached yet waits: its job says so, starts `prebuilt.yml` if nothing is running it, and `prebuilt.yml` starts `build.yml` again when the build is saved. A release refuses to publish unless every board has an image.

## Packages

| Package | What it is |
|---|---|
| `pulzr-base` | identity, network defaults, firmware journal, add-on manager |
| `pulzr-console` | the ucode API and the built console |
| `pulzr-tui` | the terminal UI |
| `pulzr-adopt` | claim and adoption |
| `pulzr-concentrator` | LoRa radio detection, forwarders, GNSS |
| `pulzr-mqtt` | the MQTT agent |
| `pulzr-wireguard` | the management tunnel |
| `pulzr-cellular` | modems, dongles and tethered phones; built in or an add-on |
| `pulzr-ap` | the setup access point |
| `pulzr-lan`, `pulzr-dns`, `pulzr-uplinks` | the router set |
| `pulzr-speedtest` | speed tests |
| `pulzr-io` | LEDs and buttons |
| `pulzr-display`, `pulzr-usb-gadget` | the TUI on HDMI and over USB |
| `pulzr-storage` | the SD card |
| `pulzr-rak-power` | the RAK7289CV2 power board watchdog |
| `pulzr-modbus`, `pulzr-zigbee`, `pulzr-zwave`, `pulzr-matter` | add-ons, one capability each, each with its own pulzr-edge binary built with that module alone |

## The docs site

This site is [Starlight](https://starlight.astro.build) with the shared [Pulzar docs theme](https://github.com/pulzar-net/docs-theme), in `docs/`. The pages are `docs/src/content/docs/*.md`. The Hardware pages are generated from `boards/*/board.conf` through `scripts/board-facts.sh` (`docs/src/boards.mjs`): a board's page and its row in the Hardware table come from the same facts, and its "Edit page" link opens its `board.conf`.

```bash
cd docs
npm ci
npm run dev
```

The `docs` workflow builds it on every pull request and publishes it to GitHub Pages from `main`.
