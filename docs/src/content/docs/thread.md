---
title: "Thread"
description: "The pulzr-thread add-on makes a gateway a Thread border router: OpenThread's otbr-agent (ot-br-posix, BSD-3-Clause), as OpenWrt's openthread-br package builds it, on a Thread radio co-processor..."
---

The `pulzr-thread` add-on makes a gateway a Thread border router: OpenThread's
`otbr-agent` (ot-br-posix, BSD-3-Clause), as OpenWrt's `openthread-br` package
builds it, on a Thread radio co-processor (RCP) plugged into the gateway. There
is no Thread stack of our own. What PulzrOS adds is the integration: the radio
`pulzr-probe` found, setup from Pulzr Net, health, and the network's state and
mesh reported as Pulzr protocol v1.

## Radios

A USB dongle running OpenThread's RCP firmware (Spinel over HDLC). On the
bench:

| Dongle | Chip | Firmware |
|---|---|---|
| Home Assistant Connect ZBT-2 | EFR32MG24 | OpenThread RCP from Nabu Casa's web flasher |
| Home Assistant Connect ZBT-1 | EFR32MG21 | the same |
| Nordic nRF52840 Dongle | nRF52840 | `ot-rcp` from ot-nrf528xx |

One radio carries one protocol: a dongle runs Zigbee or Thread firmware.

## The package

- `feed/pulzr-thread`: our files only. `upstream` names `openthread-br` and
  `ip-tiny`; `scripts/addon-upstream.sh` fetches them and every dependency a
  gateway may lack from the release's own signed feeds, and `build-addons.sh`
  publishes them unchanged beside the add-on (see [addons.md](/PulzrOS/addons.html)).
- `kmod-tun` is in every image (`boards/common/board.conf`): a kernel module
  comes with the image, never with an add-on.
- About 4 MB installed; `pulzr-addon` refuses a gateway without the room.

## On the gateway

`/etc/init.d/pulzr-thread` runs two procd instances once a radio is set up
(`pulzr_thread.main.enabled=1`, `radio=<detected radio id>`):

```
otbr-agent -I wpan0 -B <backbone> --rest-listen-address 127.0.0.1 \
  spinel+hdlc+uart:///dev/ttyACM0?uart-baudrate=460800 [trel://<backbone>]
pulzr-thread watch
```

It does not use openthread-br's netifd protocol handler; the two reasons are
under Upstream below.

- **The backbone** is `isolated` by default: a dummy link of the gateway's own
  (`thread-bb`). PulzrOS answers nothing on a customer network it was not
  asked to, and a border router on one sends router advertisements and gives
  its hosts addresses. Border routing still runs (it needs an infrastructure
  link for the OMR prefix and the SRP server Matter devices use), and devices
  on the mesh reach the gateway's own services. `backbone=devlan` or `wan` puts
  it on a real network, for a Matter controller elsewhere on it.
- **Settings** live in `/etc/pulzr-thread/otbr` (0700, kept across upgrades),
  linked from `/var/lib/thread`.
- **The firewall** puts `wpan0` in zone `thread`: UDP and ICMPv6 in (OpenThread's
  MLE, TMF, SRP and DNS run on host sockets bound to wpan0, and Matter is UDP),
  nothing else, so a Thread device cannot reach the console or SSH.
- **The REST API** listens on loopback only. It has no authentication and
  answers with the network key.

`pulzr-thread` (ucode) drives it through the REST API and `ot-ctl`:

| Command | |
|---|---|
| `status [--brief]` | radio, agent, role, ext address, RLOC16, partition, routers, border routers, children, and the dataset by `dataset_id`, never a key |
| `use <radio>` / `release` | start the border router on a radio / stop it and free the radio |
| `scan` | energy per channel, and the quietest of 15, 20 and 25 |
| `form` / `join` (stdin `{"dataset", "network"}`) | set the active dataset and start; refused while the gateway is in another network |
| `leave` | stop and erase the network, its key with it |
| `permit` (stdin `{"eui64", "pskd", "seconds"}`) / `permit-stop` | commissioner: let a device join with its joining code |
| `dataset` | the active dataset as hex TLVs, for Pulzr Net to seal |
| `topology [eui]` | protocol v1 `topology` |
| `watch` | publish `state` (every 5 minutes and on a change) and `topology` (every 15) |

Secrets come on stdin, never as arguments, which every process listing shows.

## Pulzr Net

- **Changes** go through the console API, `POST /api/system/thread/<op>` (`lib/thread.uc`),
  from an `sso` session only, as add-ons do, audited without the request. Never
  the MQTT agent: a dataset carries the network key, and that channel ends at
  the platform's broker.
- **The claim report** and the MQTT agent's `thread` op (and `all`) carry
  `pulzr-thread status --brief`, or null without the add-on.
- **Protocol v1**, as the adapter `edge-<eui>`: `pulzr/a/edge-<eui>/d/thread:<ext address>/state`
  with `network` (protocol `thread`, state, radio, name, role, channel, PAN ids,
  `dataset_id`, `active_timestamp`, routers, border routers) and `.../topology`.

## Topology

One border router per network reports the mesh: the one with the lowest RLOC16
among the border routers in the network data, so two gateways never send
competing complete views. It asks network diagnostics (`GET /diagnostics`):
each router's route table and child table.

- `thread:<border router> -> gw:<eui>`, `bus`
- each router to its next hop toward this border router, `route`, with `lq_in`,
  `lq_out` (0 to 3) and `cost`
- other router links, `neighbor`, once per pair
- each child to its parent router, `route`; a child's extended address, which
  child tables do not carry, is asked of the child once and kept by RLOC16

The other border routers send only their own `bus` edge, with `complete` false, so they never prune the reporter's view.

## Upstream

Bugs in openthread-br and ot-br-posix that PulzrOS works around, each fixed
upstream in a session of its own (submission held for the owner):

- openthread-br's netifd handler starts otbr-agent without
  `--rest-listen-address`, and ot-br-posix's default is every address: the
  unauthenticated REST API, network key included, is on the LAN.
- openthread-br keeps OpenThread's settings in `/var/lib/thread`, tmpfs on
  OpenWrt: the dataset, frame counters and prefixes are lost at every reboot,
  and the handler keeps the dataset in world-readable `/etc/config/network`.
- Noted, not worked around: ot-br-posix's `openapi.yaml` names the active
  dataset's plain content type `plain/text` and the joiner's PSKd `Pksd`; the
  server reads `text/plain` and `Pskd`.
