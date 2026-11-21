<p align="center">
  <img src="console/public/icon.svg" alt="PulzrOS" width="96" height="96">
</p>

<h1 align="center">PulzrOS</h1>

<p align="center">
  The open gateway OS for LoRaWAN, Bluetooth LE and IP devices, built on OpenWrt.
</p>

<p align="center">
  <a href="https://github.com/pulzar-net/PulzrOS/actions/workflows/build.yml"><img src="https://github.com/pulzar-net/PulzrOS/actions/workflows/build.yml/badge.svg?branch=main" alt="Build"></a>
  <a href="https://github.com/pulzar-net/PulzrOS/releases"><img src="https://img.shields.io/github/v/release/pulzar-net/PulzrOS?include_prereleases&sort=semver" alt="Release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/pulzar-net/PulzrOS" alt="License: Apache-2.0"></a>
  <a href="https://oss.pulzr.net/PulzrOS/"><img src="https://img.shields.io/badge/docs-oss.pulzr.net-4f46e5" alt="Docs"></a>
</p>

<p align="center">
  <a href="https://oss.pulzr.net/PulzrOS/"><b>Documentation</b></a> ·
  <a href="https://oss.pulzr.net/PulzrOS/getting-started">Quick start</a> ·
  <a href="https://oss.pulzr.net/PulzrOS/hardware/">Hardware</a> ·
  <a href="https://github.com/pulzar-net/PulzrOS/releases">Releases</a>
</p>

---

PulzrOS turns a Raspberry Pi, a RAK WisGate or a GL.iNet router into a managed gateway. It runs the LoRa packet forwarders, forwards Bluetooth LE, routes for IP devices, and fails over between ethernet, WiFi and cellular. A gateway adopts itself into the cloud when somebody scans its code, takes signed firmware updates, and is managed from a web console it serves itself or the same pages in a terminal over serial, SSH, HDMI or USB.

## Hardware

| Board | Radio | Install |
|---|---|---|
| Raspberry Pi 3, 4, 5 | any SPI, USB or UART concentrator, probed | SD card |
| RAK7391 WisGate Connect | two mPCIe slots, probed | SD card |
| RAK7268V2 / CV2 WisGate Edge Lite 2 | 8 channels | `sysupgrade` |
| RAK7289V2 / CV2 WisGate Edge Pro | 16 channels | `sysupgrade` |
| RAK7266, RAK7267 | 8 channels | `sysupgrade` |
| GL.iNet GL-SFT1200 Opal | none: a router for IP devices | `sysupgrade` |

Every board, with what is verified on hardware, is on the [hardware pages](https://oss.pulzr.net/PulzrOS/hardware/).

## Quick start

1. **Download** the image for your board from the [latest release](https://github.com/pulzar-net/PulzrOS/releases).
2. **Flash** it with Raspberry Pi Imager (*Use custom*), Etcher or `./flash.sh --download rpi4`.
3. **Open the console**: plug a laptop into the gateway's ethernet port and browse to `https://pulzr-<serial>.local`. Scan the claim code to adopt it.

The full walk-through is in [Getting started](https://oss.pulzr.net/PulzrOS/getting-started).

## Build from source

```bash
./build.sh rpi4
```

Needs Node 20+, `curl`, `jq`, `zstd`, and Linux or Docker for image assembly. See [Building from source](https://oss.pulzr.net/PulzrOS/building).

## Contributing

Board support, fixes and documentation are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) and the [contributor guide](https://oss.pulzr.net/PulzrOS/contributing). Commits are signed off under the DCO.

## Security

Report vulnerabilities to **security@pulzr.net**, not in an issue. See [SECURITY.md](SECURITY.md).

## License

PulzrOS is [Apache-2.0](LICENSE). Images also contain OpenWrt and its packages and the ChirpStack gateway binaries, each under its own license: see [NOTICE](NOTICE) and [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
