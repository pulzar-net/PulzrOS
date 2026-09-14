# ParkezeOS

A Parkeze-branded OpenWrt distribution for LoRaWAN gateways, managed by
[parkeze.net](../parkeze.net).

Replaces the previous Raspberry Pi OS / pi-gen build entirely. Nothing of it is
carried over.

## What it is

- **OpenWrt 24.10**, assembled with ImageBuilder from a pinned release.
- **No LuCI.** The Parkeze console replaces it: a React app served as static
  files by uhttpd over a ucode API, sharing design tokens verbatim with
  parkeze.net so the two are visibly one product.
- **One-touch provisioning.** Power on, scan the QR, pick the site. The gateway
  adopts itself; nobody types a credential into it.
- **Multi-board from one tree.** A board is a page of deltas over a shared
  config, not a fork. Pi 3/4/5 as kits, two RAK units as fixed hardware.
- **Concentrator slots**, so an 8-channel Pi and a 16-channel RAK7289CV2 run
  the same code. Auto-detection across SPI, USB and UART on kit boards, with
  everything operator-correctable from the console.
- **Full front panel** — LEDs and buttons mapped per board, driven from real
  state, with a lamp test for bring-up.
- **GNSS** over UART or USB, auto-detected, feeding real GPS time to the packet
  forwarder — and honest about the difference between a live fix and the
  position the gateway is announcing.
- **Generated login banner** — the wordmark is rendered by figlet at print
  time, not pasted into a file, and the facts under it are read live.
- **Two management paths** — Tailscale over wired, 1NCE over cellular — with
  Tailscale structurally prevented from ever touching the metered link.
- **A way back in** — a setup AP and captive portal for a gateway that has
  dropped off the network, open only while it has no credentials to lose, and
  a LAN DHCP server that refuses to run on somebody else's network.

## Quick start

```bash
./build.sh --list          # what is buildable
./build.sh rpi4            # build one board
./build.sh --all           # build everything
```

`build.sh` builds the React console, packages the feed, and assembles images,
in that order.

## Flashing one

```bash
./flash.sh --download rpi4     # fetch the latest CI image and write it to a card
```

Refuses internal disks, never guesses the target, and asks you to type the disk
identifier rather than press `y`. See [`docs/flashing.md`](docs/flashing.md).

## Building

Images land in `out/<board>/`. First build downloads and checksum-verifies an
ImageBuilder (~150MB, cached); after that a build is a few minutes.

**Image assembly requires Linux.** OpenWrt's ImageBuilder is a tree of prebuilt
x86_64 ELF binaries with no macOS build, so `build.sh` refuses to run on a Mac
and prints a `docker run` line that does the same job. The package feed
(`scripts/build-feed.sh`) *does* build natively on macOS, which is enough to
iterate on the console and the packages — verified, including executable bits
and the opkg index.

Requires `node` (20+), `curl` and `zstd`, plus GNU `tar` for byte-reproducible
packages: `brew install node zstd gnu-tar`. Without gnu-tar the packages are
still correct, just not byte-reproducible.

To bake the fleet recovery anchor into the image — required for offline
adoption — point `PARKEZE_RECOVERY_PUBKEY` at the public half of the key from
`parkeze.net/tools/generate-recovery-key.sh`.

## Layout

```
boards/           one per board; common/ holds everything shared
  common/board.conf        sourced by every board
  common/raspberrypi.conf  the kit boards
  common/rakwireless.conf  the fixed-hardware boards
console/          the React console. Built to static files by build.sh and
                  packaged into parkeze-console; no Node on the gateway.
feed/             the Parkeze OpenWrt package feed
  parkeze-base          identity, network defaults, branding
  parkeze-console       the LuCI replacement: ucode API + the built SPA
  parkeze-concentrator  slot detection, profiles, packet forwarders
  parkeze-cellular      modem, data frugality, backhaul health
  parkeze-tailscale     tailnet node, pinned to the wired uplink
  parkeze-adopt         one-touch provisioning and adoption
  parkeze-io            front-panel LEDs and buttons
  parkeze-ap            setup AP, captive portal, LAN DHCP guard
scripts/          build-feed.sh, check-ucode.sh, ucode stubs
docs/             the design decisions worth writing down
```

## Documentation

- [`docs/backhaul.md`](docs/backhaul.md) — the two uplinks, the two management
  paths, and why Tailscale is structurally barred from cellular.
- [`docs/auth.md`](docs/auth.md) — how you get into a gateway, including the
  offline Ed25519 recovery flow and why a stored break-glass password would be
  the wrong answer.
- [`docs/access.md`](docs/access.md) — the setup AP, the captive portal, and
  why forcing a gateway offline to raise its radio gains an attacker nothing.
- [`docs/flashing.md`](docs/flashing.md) — getting an image onto a board, and
  the first-boot experience.
- [`docs/provisioning.md`](docs/provisioning.md) — one-touch provisioning end
  to end, the two secrets it rests on, and what happens when a gateway has no
  internet.
- [`docs/concentrators.md`](docs/concentrators.md) — slots, why 16 channels is
  two concentrators, and kit versus product boards.
- [`docs/boards.md`](docs/boards.md) — adding a board, and adding a
  concentrator.
- [`devices/README.md`](devices/README.md) — porting a board OpenWrt does not
  support, and why the flash layout has to come off the hardware rather than a
  datasheet.

## Development

The console has two halves. The React app typechecks and builds normally:

```bash
cd console && npm install && npm run typecheck && npm run build
npm run dev            # against a gateway: PARKEZE_GATEWAY=https://<ip> npm run dev
```

Its API is ucode, which does not exist on a Mac. Syntax-check that before
flashing anything:

```bash
git clone --depth 1 https://github.com/jow-/ucode /tmp/ucode
cmake -B /tmp/ucode/build -DFS_SUPPORT=ON /tmp/ucode && cmake --build /tmp/ucode/build
UCODE=/tmp/ucode/build/ucode scripts/check-ucode.sh
```

That resolves `fs`, `uci`, `ubus` and `digest` against the stubs in
`scripts/ucode-stubs/`, so it catches importing a function that does not exist
as well as plain syntax errors. Keep the stubs honest when you reach for a new
one.

## Status

Everything here is written but **none of it has been run on hardware**. The
build pipeline, the ucode modules and the cryptography have been verified as
far as they can be off-device — see the note at the end of the handover for
exactly what was and was not checked.
