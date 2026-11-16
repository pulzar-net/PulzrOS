# PulzarOS

An OpenWrt 25.12 distribution for LoRaWAN and Bluetooth LE gateways. It turns a
Raspberry Pi or a RAK WisGate into a managed LoRaWAN gateway with a local
console, a terminal UI, and one-touch adoption into a cloud.

PulzarOS is built with OpenWrt's ImageBuilder from a pinned release. There is
no LuCI: the gateway console is a React app served by uhttpd over a ucode API,
and the same pages are available in a terminal over serial, SSH and USB.

## What it does

- **LoRaWAN gateway.** ChirpStack Concentratord and the MQTT Forwarder, with
  concentrator slots so an 8-channel Pi and a 16-channel RAK7289CV2 run the same
  code. SPI, USB and UART concentrators are detected on kit boards and
  everything is correctable from the console.
- **Bluetooth LE.** Advertisement forwarding over MQTT where the board has it.
- **One-touch adoption.** Power on, scan the QR on the console or the SSH
  banner, pick the site. The gateway adopts itself; nobody types a credential
  into it. See [`docs/provisioning.md`](docs/provisioning.md).
- **Two management paths.** A WireGuard tunnel over wired, and a cellular path
  over a SIM, with the tunnel structurally barred from ever using the metered
  link. See [`docs/backhaul.md`](docs/backhaul.md).
- **A way back in.** One ethernet port is the uplink and the console port at
  once, reachable at `pulzr-<serial>.local` from a laptop and a cable with
  nothing configured; four presses of the reset button raise a setup AP.
- **Front panel.** LEDs and buttons mapped per board and driven from real state.
- **GNSS** over UART or USB, feeding real GPS time to the forwarder.
- **Local console, three ways.** The web console, the same pages as a TUI on the
  serial console, over SSH (`ssh pulzr@<gateway>`), on a Pi's own screen, and
  over a USB cable that is also a network (`pulzr.local`).

## Boards

| Board | ID | Concentrator |
|---|---|---|
| Raspberry Pi 3 | `rpi3` | kit (HAT, USB, UART), probed |
| Raspberry Pi 4 | `rpi4` | kit, probed |
| Raspberry Pi 5 | `rpi5` | kit, probed |
| RAK7268C WisGate Edge Lite 2 | `rak7268c` | fixed |
| RAK7268CV2 WisGate Edge Lite 2 | `rak7268cv2` | fixed |
| RAK7289CV2 WisGate Edge Pro | `rak7289cv2` | fixed, 2 x 8 channels |
| GL.iNet GL-SFT1200 (Opal) | `gl-sft1200` | none: a router for LAN, uplinks and DNS |

A board is a page of deltas over a shared configuration, not a fork. See
[`docs/boards.md`](docs/boards.md) to add one.

## Build

```bash
./build.sh --list          # what is buildable
./build.sh rpi4            # build one board
./build.sh --all           # build everything
```

`build.sh` builds the React console, stages the package feed, and assembles
images in that order. Images land in `out/<board>/`. The first build downloads
and checksum-verifies an ImageBuilder (about 150 MB, cached).

Image assembly needs Linux: OpenWrt's ImageBuilder is prebuilt x86_64 ELF
binaries. On a Mac `build.sh` runs that step in Docker. You need `node` (20+),
`curl`, `jq` and `zstd`, plus GNU `tar` for byte-reproducible packages.

Three public keys decide whom an image trusts. None is secret:

| Variable | What it is |
|---|---|
| `PULZR_RECOVERY_PUBKEY` | the Ed25519 key an offline adoption is signed with |
| `PULZR_FIRMWARE_PUBKEY` | the Ed25519 key firmware updates must be signed with |
| `PULZR_SSH_CA_PUBKEY` | the SSH CA whose certificates root accepts (default `boards/common/ssh/pulzr_user_ca.pub`) |

`boards/common/ssh/` also holds the operator fleet key that goes into root's
`authorized_keys` (`fleet/pulzr-fleet.pub`). The ones in this tree are
Pulzar's: **replace the CA and the fleet key with your own before building
images for your own fleet.** Without the recovery and firmware keys the build
warns and produces an image that cannot be adopted offline or check an
update's signature. See [`docs/auth.md`](docs/auth.md).

`PULZR_DEV=1 ./build.sh <board>` builds a development image: a root shell on the
serial console, failsafe, and your key from `boards/common/ssh/dev/`. Its
version ends in `-dev`; the CI workflow refuses to build one for release.

## Flash

```bash
./flash.sh --download rpi4     # fetch the latest CI image and write it to a card
```

`flash.sh` refuses internal disks, never guesses the target, and asks you to
type the disk identifier rather than press `y`. The images are raw disk images,
not ISOs: any SD writer (Raspberry Pi Imager's *Use custom*, Etcher, Rufus) can
write the `.img.xz`. A RAK unit is upgraded from its console or with
`sysupgrade`. See [`docs/flashing.md`](docs/flashing.md).

## Adopt

A gateway needs a cloud to adopt into. By default that is Pulzar Cloud at
`https://app.pulzr.net`: scan the code the gateway shows, sign in, pick an
organization.

To adopt into your own cloud, build with `PULZR_NET_URL` (and
`PULZR_MQTT_HOST` for the first-contact broker) set in `boards/common/board.conf`
to a server that implements the gateway API the scripts call under
`/api/v1/gateway-ops/` — claim registration and polling, adoption, reporting and
WireGuard enrolment. [`docs/provisioning.md`](docs/provisioning.md) walks the
protocol and the two secrets it rests on.

## Layout

```
boards/           one directory per board; common/ holds everything shared
console/          the React console, built to static files by build.sh
feed/             the OpenWrt package feed (pulzr-*)
sdk/              the LoRa packages, built with the OpenWrt SDK
scripts/          build-feed.sh, the checks and the tests
docs/             design decisions worth writing down
```

Packages: `pulzr-base` (identity, network defaults), `pulzr-console` (ucode API
and the built SPA), `pulzr-concentrator`, `pulzr-cellular`, `pulzr-wireguard`,
`pulzr-adopt`, `pulzr-io`, `pulzr-ap`, `pulzr-tui`, `pulzr-display`,
`pulzr-usb-gadget`, `pulzr-lan`, `pulzr-dns`, `pulzr-uplinks`, `pulzr-speedtest`,
`pulzr-storage`, `pulzr-ble`, `pulzr-mqtt`, `pulzr-rak-power`, and `pulzr-edge`
(the Modbus daemon, from its own repository's releases; in no image yet).

## Development

The console typechecks and builds normally:

```bash
cd console && npm install && npm run typecheck && npm run build
npm run dev            # against a gateway: PULZR_GATEWAY=https://<ip> npm run dev
```

Its API is ucode, which does not exist on a Mac. Build it once and the checks
run anywhere:

```bash
git clone --depth 1 https://github.com/jow-/ucode /tmp/ucode
cmake -B /tmp/ucode/build -DFS_SUPPORT=ON /tmp/ucode && cmake --build /tmp/ucode/build
UCODE=/tmp/ucode/build/ucode scripts/check-ucode.sh
python3 scripts/check-ucode-scope.py
for t in scripts/test-*.sh; do UCODE=/tmp/ucode/build/ucode bash "$t"; done
UCODE=/tmp/ucode/build/ucode scripts/run-tui.sh     # the TUI, on canned state
```

`check-ucode.sh` resolves `fs`, `uci`, `ubus` and `digest` against the stubs in
`scripts/ucode-stubs/`, so it catches importing a function that does not exist
as well as syntax errors. [`CLAUDE.md`](CLAUDE.md) lists the rules the checks
enforce, and the conventions for the console's text.

## Upgrading from ParkezeOS

Gateways that ran the earlier name keep their identity, secrets and settings
across the upgrade: `pulzr-legacy` moves the old state to the new paths on
first boot and keeps the old copies current so a rollback finds them.
[`docs/legacy-migration.md`](docs/legacy-migration.md).

## Contributing, security, licence

[`CONTRIBUTING.md`](CONTRIBUTING.md) (DCO sign-off),
[`SECURITY.md`](SECURITY.md) (security@pulzr.net),
[`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md).

PulzarOS's code is Apache-2.0 ([`LICENSE`](LICENSE), [`NOTICE`](NOTICE)).
Images also contain OpenWrt and its packages, each under its own licence, and
the ChirpStack gateway binaries: see
[`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md).

## Status

The build pipeline, the ucode modules and the cryptography are checked as far
as they can be off-device by the scripts above; behaviour on hardware is
described in the docs board by board, including what is still unverified.
