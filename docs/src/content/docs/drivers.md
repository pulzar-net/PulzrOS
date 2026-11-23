---
title: "Device drivers"
description: "A device type's package may carry a driver: a ucode script that speaks that device's own protocol. Pulzar delivers it to the gateways that have such a device and pulzr-drivers runs it, sandboxed, one process per command."
---

Nothing device-specific is built into PulzarOS. A device on the LAN that does
not speak the Pulzar protocol itself (an IP camera with its own settings API)
is an adapter device, `ext:<family>.<id>`, whose type's package carries
`driver.uc`. The gateway runs it with `pulzr-drivers`, in every image with a
LAN.

| | |
|---|---|
| Where the driver comes from | The device type's package (`driver.uc` beside `device.json` and `commands.json`), published to Pulzar |
| How it arrives | `POST /api/v1/gateway-ops/drivers`, proved with the claim secret: each device's key, address, credentials and driver SHA-256, and the sources this gateway lacks |
| When | At start, when the management agent's `drivers` op says something changed, and before a command when the copy is over a minute old or names no such device |
| Checked | Each source against the hash it was named by, at delivery and again before every run |
| Kept | `/var/run/pulzr-drivers`, RAM. The manifest, which holds the credentials, is root-only |
| Runs as | `pzdrv<n>` (uid 61000 + n, one per device, at most 16) |
| May reach | Its device's address, nothing else: an nft table of its own (`inet pulzr_drivers`) rejects every other destination, loopback included |
| Limits | 20 s of CPU, 64 MB of address space, 32 processes, 30 s of wall time |

## One command

```
Pulzar ── pulzr/a/edge-<EUI>/d/<key>/cmd ──▶ pulzr-drivers ── stdin ──▶ ucode driver.uc (pzdrv<n>) ──▶ the device
       ◀── .../cmd/res: queued, then the driver's answer ──────────── stdout ◀─┘
```

The driver reads one JSON document on stdin:

```json
{ "name": "user.add", "params": { "username": "site", "password": "…", "group": "viewer" },
  "by": { "sub": "…", "role": "admin" },
  "device": { "key": "ext:camera.f0000610916b", "address": "10.0.0.112",
              "credentials": { "username": "admin", "password": "…" } },
  "tmp": "/var/run/pulzr-drivers/tmp/61000" }
```

and prints one answer, the protocol's `cmd/res` without `v` and `id`:

```json
{ "status": "ok", "data": { "users": [ … ] } }
{ "status": "refused", "reason": "invalid", "detail": "the camera has no user site" }
```

- Params the package marks `"secret": true` arrive opened, on the pipe only:
  never an argument, the environment or a file of the runner's. A driver keeps
  them off command lines too (curl and openssl read them from a file in `tmp`,
  which is the driver's alone and emptied after every command).
- `credentials` are set on the device in Pulzar (`PATCH
  /api/v1/adapter-devices/<devEui>`), sealed there, and never shown again.
- A key with no driver here (a Modbus unit) is left to its own module.
- An expired command or another protocol version is answered without running
  the driver; a driver that prints no answer, or whose file no longer matches
  its hash, is `failed error`.
- The log names the device, the command and the outcome, never the params.

A driver may use what the image ships: ucode with its `fs` module, curl and
openssl.

`pulzr-drivers sync` pulls by hand and prints what is held, without the
credentials; `pulzr-drivers rules` prints the fence.
