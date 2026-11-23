---
title: "Security model"
description: "Gateways sit in public places, often on a pole, sometimes with no uplink."
---

Gateways sit in public places, often on a pole, sometimes with no uplink. The design assumes somebody will hold one, plug into it and read its label.

## Reporting a vulnerability

Email **security@pulzr.net**. Do not open a public issue. See [`SECURITY.md`](https://github.com/pulzar-net/PulzrOS/blob/main/SECURITY.md) for what to include, response times and scope.

## What protects a gateway

| Concern | How |
|---|---|
| Adoption | A claim secret that never leaves the gateway; the cloud holds only its SHA-256. Nobody types a credential into the gateway. [Provisioning](/PulzrOS/provisioning.html) |
| Console sign-in | Local password only while unadopted. Once adopted: your cloud account, or offline recovery signed by the fleet's recovery key. [Authentication](/PulzrOS/auth.html) |
| Root | No password. SSH as root takes the fleet key or a five-minute certificate signed for this gateway's EUI. Organization admins use the console, never a shell. [Who gets root](/PulzrOS/auth.html#who-gets-root) |
| Local ports | The ethernet port is the console port and never serves DHCP. The setup AP is off unless raised by the reset button, and only when no uplink works. [Setup access](/PulzrOS/access.html) |
| Firmware | Ed25519-signed images, checked on the gateway before writing. [Firmware](/PulzrOS/firmware.html) |
| Add-ons | A signed apk repository per release, pinned to the exact base package. [Add-ons](/PulzrOS/addons.html) |
| Management | A WireGuard tunnel that cannot leave on a metered link, or the SIM provider's private network. [Backhaul](/PulzrOS/backhaul.html) |
| Image build | `uci-defaults` scripts are guarded so none runs against the build host; CI checks it. |

## What is not covered

Physical access to storage. A Pi's root filesystem is a plain squashfs on its SD card, and a RAK's is in flash its U-Boot hands to anyone on the serial header. Closing that is secure boot and encrypted storage, which a Pi 4 or 5 can be made to do and the MT7628 cannot.

## Keys

No secret belongs in the repository. Everything in `boards/common/ssh/` is a public key. An image is built with the public halves of:

| Variable | Key |
|---|---|
| `PULZR_RECOVERY_PUBKEY` | Ed25519 key that signs offline recovery |
| `PULZR_FIRMWARE_PUBKEY` | Ed25519 key that signs firmware |
| `PULZR_SSH_CA_PUBKEY` | SSH user CA whose certificates root accepts |

The CA and fleet key in this tree are Pulzr's. Replace them before building for your own fleet: [Building from source](/PulzrOS/building.html#keys).
