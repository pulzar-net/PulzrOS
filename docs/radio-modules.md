# Radio modules: the gateway contract

A radio module is the part of `pulzr-edge` that runs one coordinator: a Zigbee
network on an EmberZNet or Z-Stack dongle, a Z-Wave network on a Serial API
controller. Every module implements the same contract, so Pulzar Net drives
them all with one set of screens: set up, pair, back up, restore, remove,
replace, change channel, delete.

Thread is not a module. Its border router is OpenThread's `otbr-agent`, which
the pulzr-thread add-on runs, and it has its own console path
(`system/thread/*`, [thread.md](thread.md)). What a Thread network shares with
these is the platform's record of it and the person-only rule below.

## Who may change a network

Only a person, from Pulzar Net, as an add-on install is. Every operation that
changes a network or carries a key arrives through the gateway's console API
over gateway-link, as that person's `sso` session, and is audited on the
platform with who did it and without its secrets. A local console session can
read status and nothing else.

Never over MQTT. A `cmd` reaches a gateway from API keys and agents as well as
people, and the agent's channel ends at an in-cluster broker. So the
coordinator's key takes no `network.*` command; opening a network for joining
is as much a person's act as forming it.

What flows the other way, the module telling the platform what happened, goes
over MQTT as protocol v1 `event` and `state` messages, because none of it is
secret. Backups do carry keys, so they go over HTTPS with the gateway's claim
proof, never MQTT.

```
Pulzar Net ──gateway-link──▶ console API ──stdin──▶ pulzr-edge radio <id> <op> ──socket──▶ pulzr-edge radio serve <id>
     ▲                       (sso session)                                                     │
     ├──────────── MQTT: event / state on the coordinator's key ◀──────────────────────────────┤
     └──────────── HTTPS, claim proof: backups (pulzr-radios backup) ◀─────────────────────────┘
```

## The path on the gateway

1. **Console API.** `POST /api/system/radio/<op>` with a JSON body naming
   the radio, `{"radio": "usb-10c4_ea60-9e2adbd1", ...}` (pulzr-probe's
   detected id); `GET /api/system/radio` for every module's status.
   `lib/radio.uc` checks the session (`sso` for every POST), the radio id
   and the op name, and hands the rest of the body on.
2. **`use` and `release` are the gateway's.** `pulzr-radios use <radio id>
   <protocol>` writes the radio's file and starts its process (one procd
   instance per radio); `release` stops it and removes the file, and is
   refused while a network is on the radio.
3. **`pulzr-radios call <radio id> <op>`** for every other op, which runs
   `pulzr-edge-<protocol> radio <radio id> <op>`, the radio's module binary. The request
   body arrives on stdin, never on the command line, from a file only root
   can read that is removed before the answer goes back. The command
   connects to that radio's control socket and prints the result as one JSON
   object. Exit 0 with the result; with the reason on stderr, exit 2 for a
   bad request (400), 1 for a refusal or busy (409), 3 when no module runs
   on that radio.
4. **One process per radio**, `pulzr-edge radio serve <radio id> <config>`,
   so one stack failing never takes another network down. Its control
   socket is `/var/run/pulzr-edge/radio/<radio id>.sock`, mode 0600 in a
   0700 directory. One request line `{"radio", "op", "params"}`, one answer
   line `{"ok": true, "result": {...}}` or `{"ok": false, "error": "...",
   "code": "bad-request" | "refused" | "busy"}`. One change at a time.
5. **The module** does it, bounded: every op answers within 30 s. Anything
   longer (an inclusion) answers once it has started and reports the rest as
   events.

## Keys and state at rest

A module keeps its network in `/etc/pulzr-edge/radios/<radio id>.json`, mode
0600, root, written atomically and kept across upgrades. It holds the radio id,
the protocol, the platform's network id, and the keys. No key is ever in a log
line, an event, `state`, a `cmd/res` or a crash report.

The module finds its port from pulzr-probe's report
(`/var/run/pulzr-probe/radios.json`, the radio's `port`) each time it starts,
because `ttyUSB` numbers change across reboots and the radio id does not.

## Operations

Every op names its radio. Parameters in **bold** are secrets: they arrive on
stdin only and are never echoed back. `network` is the platform's id for the
network (a UUID); the module stores it and puts it in `status` and every
backup, so a backup can never be restored into the wrong record.

| Op | Params | Result |
|---|---|---|
| `status` | | [Status](#status) |
| `use` | `protocol` (`zigbee`, `zwave`) | the gateway starts the radio's module, unformed; status |
| `release` | | the gateway stops it; refused while a network is on it |
| `scan` | `seconds` (≤ 10) | Zigbee: `{"channels": [{"channel", "energy", "networks"}]}`, energy 0–255 and the PAN ids heard. Z-Wave: refused |
| `form` | `network`, protocol params below | a new network on the radio; status once it is up |
| `restore` | `network`, **`backup`**, `force` | the backup written to this radio; status |
| `backup` | | **`{"backup": {...}}`**: the same object the module pushes (below) |
| `leave` | `erase` | forgets the network and its keys; with `erase`, also wipes it from the radio (Z-Wave: the controller back to factory) |
| `permit` | `seconds` (30–600, default 180), `via` (a router's device key, or none for the coordinator) | `{"until"}` |
| `permit-stop` | | `{"until": null}` |
| `provision` | **`entries`** | the whole provisioning list, replacing the module's; `{"count"}` |
| `grant` | `request`, `classes`, `client_auth` | Z-Wave S2: the keys the person grants a joining device |
| `dsk` | `request`, **`pin`** | Z-Wave S2: the five digits the person read off the device |
| `abort` | | stops a running inclusion, exclusion or replace |
| `remove` | `device` (its key), `force` | Zigbee: a leave request, then the device is dropped. Z-Wave: exclusion, waiting for the device's button, or with `force` the failed-node removal |
| `replace` | `device` | Z-Wave: replace a failed node, keeping its node id. Zigbee: refused |
| `channel` | `channel` (11–26) | Zigbee: moves the network (a network update broadcast). Z-Wave: refused |
| `region` | `region` | Z-Wave: the RF region. Zigbee: refused |
| `map` | | `{"started": true, "requests"}` at once; then the module walks the mesh one request at a time (Zigbee: neighbor and routing tables per router; Z-Wave: routing info per node), skipping sleepy end devices, and publishes v1 `topology` with `source: "scan"`, `complete: true`. `busy` while joining, an inclusion or an OTA runs |

`form`, by protocol:

- Zigbee: `channel`, `pan_id` (4 hex), `ext_pan_id` (16 hex),
  **`network_key`** (32 hex), `legacy` (pre-3.0 devices may join with the
  well-known link key; default true), `install_codes_only` (default false).
  The coordinator's IEEE address is the dongle's own.
- Z-Wave: `region`, **`keys`** (`s0`, `s2_unauthenticated`,
  `s2_authenticated`, `s2_access_control`, `lr_s2_authenticated`,
  `lr_s2_access_control`, each 32 hex), `erase` (required when the controller
  already has nodes; without it the module refuses and says how many).

`provision` entries:

- Zigbee: `{"ieee", "install_code"}`; the install code with its CRC, as
  printed.
- Z-Wave SmartStart: `{"dsk", "classes", "protocol": "zwave" | "lr",
  "name"}`, as read from the QR code.

### Status

```json
{
  "radio": "usb-10c4_ea60-9e2adbd1", "protocol": "zigbee",
  "network": "5d4c…", "state": "up",
  "firmware": "7.4.4.0", "ncp": "ezsp",
  "coordinator": "zigbee:00124b0012345678",
  "channel": 15, "pan_id": "1a2b", "ext_pan_id": "dd5e3c9a0b1c2d3e",
  "region": null, "home_id": null,
  "devices": 23,
  "joining": { "until": 1795619170, "via": null },
  "inclusion": null,
  "backup_at": 1795618990
}
```

`state` is `unformed` (in use, no network yet), then protocol v1's
`forming`, `up`, `degraded`, `down`, `restoring`. Z-Wave fills `region`,
`home_id` and the coordinator `zwave:<home id>.1` instead of the PAN ids.
`inclusion` is the running S2 inclusion, as its last event says.

## Events

Published on the coordinator's key as protocol v1 `event` (`name`, `data`);
the platform turns them into the live pairing stream. None carries a key.

| `name` | `data` |
|---|---|
| `network.permit` | `until`, `via` (null when it closes) |
| `network.joined` | `device`, `via`, `rssi` |
| `network.interview` | `device`, `complete`; the interview itself goes in the device's `state.interview` |
| `network.configured` | `device`: bindings and reporting set up |
| `network.left` | `device`, `reason` (`removed`, `left`, `replaced`, `failed`) |
| `network.inclusion` | `request`, `stage` (`grant`, `dsk`, `done`, `failed`), `requested` classes, `client_auth`, `dsk` with its first five digits as `xxxxx`, `granted`, `reason` |
| `network.exclusion` | `stage` (`waiting`, `done`, `failed`), `device` |
| `network.backup` | `at`, `bytes` |
| `network.channel` | `channel`, `from` |
| `network.error` | `message`; with `sev` |

`state.network` on the same key carries what [Status](#status) does, minus
`inclusion`, whenever it changes.

## Backups

The module takes a backup after every join, leave, inclusion, exclusion or
replace (at most one a minute), and on a schedule: Zigbee hourly, Z-Wave
daily. It writes it to `/var/run/pulzr-edge/backup/<radio id>.json` (0600) and
runs `pulzr-radios backup <radio id>`, which posts it to Pulzar Net with the
gateway's claim proof and removes the file. Pulzar Net seals it and keeps the
latest ones.

A backup is one JSON object:

```json
{ "v": 1, "protocol": "zigbee", "network": "5d4c…", "radio": "usb-10c4_ea60-9e2adbd1",
  "taken_at": 1795618990, "firmware": "7.4.4.0", "zigbee": { … } }
```

- `zigbee` is the [open coordinator backup](https://github.com/zigpy/open-coordinator-backup)
  format, version 1: network key and sequence, PAN ids, channel, the
  coordinator's IEEE address, the outgoing frame counter and the devices with
  their link keys. It is what Zigbee2MQTT and ZHA read, so a network can move
  in and out.
- `zwave` is `{"series": 500 | 700 | 800, "home_id", "nvm"}`, the
  controller's NVM image in base64, plus the S2 keys, which live on the host
  and not in the NVM.

`restore` refuses, with the reason in `error`:

- a backup of another network (`network` differs) or protocol;
- Zigbee: a dongle whose IEEE address cannot be set to the backup's, unless
  `force` (the devices then have to rejoin);
- Z-Wave: a series the module cannot convert the NVM to.

The frame counter goes up by a safe margin (Zigbee: 1,000,000), so devices
never see an old one.

## In the claim report

`pulzr-radios facts` puts each module's status in the six-hourly report, as
`radios.networks`, so the platform hears of networks even when MQTT is down:

```json
{ "detected": [ … ], "networks": [ { …the status above… } ] }
```

## Firmware for devices

A module that updates its devices' firmware (Zigbee OTA, Z-Wave) fetches it
only over https, from a host in `[firmware] hosts` of its config, which
PulzrOS writes from `pulzr.edge.firmware_hosts` (empty by default: nothing is
fetched). Anything else is refused as invalid.

## Matter

A gateway's controller in its organization's Matter fabric is the radio
`matter`: one `pulzr-edge radio serve matter`, on no port of its own (Matter
rides on IP, and on Thread through the border router), driven like any other.
`pulzr-radios use matter matter` starts it.

One fabric per organization. Pulzar Net's device CA holds its root and IPK; a
gateway joins with an intermediate certificate (ICAC) for a key it makes and
keeps, and signs its devices' and its own operational certificates itself,
from a range of node ids no other gateway in the fabric is given.

| Op | Params | Result |
|---|---|---|
| `status` | | `{state, fabric_id, compressed_fabric_id, node_id, devices, node_ids_left, commissioning}` |
| `csr` | | `{csr}`: hex DER PKCS#10 for a P-256 key the module keeps |
| `join` | `network`, `fabric_id`, `compressed_fabric_id`, `rcac`, `icac` (hex DER, Matter profile), **`ipk`**, `node_ids` `{first, last}`, `admin_cat` | status; again later with a new ICAC or range |
| `commission` | **`code`** (the QR payload or the manual code), `thread_network` | answers when started; progress as events |
| `share` | `device`, `seconds` (180–900) | **`{manual_code, qr_code}`**: a commissioning window for another controller |
| `decommission` | `device` | |
| `leave` | `erase` | forgets the fabric and its keys |
| `abort` | | stops a commissioning |

Events on the controller's key `matter:<compressed fabric id>.<node id>`:
`network.commission` with `stage` (discovery, pase, arm_fail_safe,
device_attestation, csr_request, add_trusted_root_certificate, add_noc,
network_setup, network_connect, find_operational, commissioning_complete,
interview), `device` and `reason`; `network.left`; `network.error`. Devices
are `matter:<compressed fabric id>.<node id>`.

## Which modules run

Each module is its own binary, pulzr-edge built with that module alone, in
its protocol's add-on: `pulzr-edge-zigbee` in pulzr-zigbee, `pulzr-edge-zwave`
in pulzr-zwave, `pulzr-edge-matter` in pulzr-matter. A radio runs where its
protocol's binary is installed: `pulzr-radios runnable` lists the radios whose
module is there, with its binary, and pulzr-edge-radios starts each with it.
So a gateway locked off a capability never runs it, and `use` refuses a
protocol whose add-on is missing. `pulzr-radios call <radio id> <op>` runs one
op through the radio's binary; the console API and the health checks use it.

## Implementing a module

A module implements `pulzr_edge::radio::RadioModule` and adds itself to
`radio::factory`; `RadioCtx` gives it its port, its file, events and
`backup()`. It:

- answers every op above or `refused` with a reason a person can act on;
- never writes to its radio before `use`, and never forms without `form`;
- keeps its keys only in its file under `/etc/pulzr-edge/radios/`;
- publishes the events and `state.network`, and takes the backups;
- holds its port open for as long as it runs, so pulzr-probe reports the
  radio `in-use` and never probes it.
