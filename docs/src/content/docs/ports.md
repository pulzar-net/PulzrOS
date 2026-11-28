---
title: "Ports and VLANs"
description: "Each Ethernet port is an uplink, a LAN port for devices (the devlan zone, lan.md), or unused, and can carry tagged VLANs, each with a role of its own."
---

Each Ethernet port is an **uplink**, a **LAN** port for devices (the devlan
zone, [lan.md](/PulzrOS/lan.html)), or **unused**, and can carry tagged VLANs, each with
a role of its own. In the console a port in the Network page's diagram opens
its role and VLANs; on the gateway it is `pulzr-ports`.

## Why roles, and where VLANs come in

On a router board the switch is DSA: every jack is its own Linux device
(`wan`, `lan1`, `lan2` on the Opal). Making the WAN jack a LAN port, or a LAN
jack a second uplink, is a role and nothing else.

A VLAN is a role on a tag: `wan.20` as a second uplink on the same cable, or
devices behind a managed switch's tagged port. The kernel tags (8021q), so it
works on any NIC. On a Pi or a RAK with one Ethernet port it is the only way
to have a second uplink, or a LAN at all. A port can be unused untagged and
carry VLANs: a trunk.

Checked on the Opal (mxl-gsw1xx, GSWIP): a VLAN on a port is accepted and
removed cleanly. Tags on the wire need a tagged switch on the far end to see.

## What a layout becomes

`pulzr-ports render` writes it into network, firewall and dhcp:

| | |
|---|---|
| An uplink | a netifd interface in the wan zone: `wan` for the board's uplink port untagged, `wan_<device>` for any other (`wan_lan1`, `wan_wan_20`). A link keeps its name, its place in the order and its tracking when another is added. |
| A LAN link | a member of `br-devlan`, isolated from the other members |
| A VLAN | a `vlan_<port>_<vid>` 8021q device |
| The console's `192.168.61.1` and `169.254.61.1` | on the board's uplink port while it is an uplink, else the first port that is one, and nowhere when none is: a LAN port already answers at `192.168.64.1` with DHCP |
| dnsmasq | never answers on an uplink's device |
| pulzr-uplinks | a new wired uplink is tracked and goes after the last wired one in the order |

The layout and each uplink's addressing live in `/etc/config/pulzr`
(`port_<name>`, `vlan_<name>_<vid>`). `19-pulzr-ports` seeds it from the
board, keeping whatever `network.wan` had, before `20-pulzr-network`
rebuilds the defaults; `29-pulzr-ports` writes it back over them.

## Kept only once confirmed

A port change can cut off whoever makes it: the laptop on the LAN jack that
becomes an uplink, or the tunnel on the uplink that becomes a LAN port when
the change came through Pulzr Cloud. So:

1. `set` keeps the configuration it replaces on flash
   (`/etc/pulzr/apply/rollback`, by `pulzr-apply`, which the console's other network setters arm the same way), applies the new one, and starts a timer.
2. The page confirms by reaching the gateway again, no sooner than 15 seconds
   after the reload finished (`confirm` refuses earlier: the network is still
   moving).
3. Nothing confirms within 90 seconds: the old configuration comes back. A
   reboot inside the window undoes it at boot, before the network starts
   (`/etc/init.d/pulzr-ports`, START=11).

A pending change has a name (`pulzr-apply arm -d`: "Port layout", "Wi-Fi
uplink: Campo"), which `status` and the console's notice show, so a change
somebody else made says what it was.

A WiFi join is also kept by the gateway itself: the API settles it with the
uplink it joined (`pulzr-apply settle -p wwifi2`), and the timer keeps the
change as soon as that uplink's own check (`pulzr-wifi-uplink status`) says
open, asked after the change took effect. A join that never gets there is
undone at the deadline as before. WiFi joins get 150 seconds: a second
radio's handover takes up to two minutes to prove itself.

The console keeps confirming after you leave the page the change was made
on. It used to stop, which is how a WiFi uplink moved on the Campo gateway
(26 Nov 2026) joined fine and was undone ninety seconds later anyway.

A second change inside the window keeps the first snapshot, the one known to
work. At least one port has to stay an uplink or a LAN port untagged, so a
plain cable always finds the console.

Checked on the Opal, 2026-11-08: `wan`, which carried the tunnel, made unused
and not confirmed; the gateway was unreachable, undid it 99 seconds later and
was back on the tunnel 17 seconds after that.

## Managing it

```
pulzr-ports status          every port, its role, VLANs, addressing, a pending change
pulzr-ports set <file>|-    a whole layout as JSON; undone unless confirmed
pulzr-ports confirm         keep it (exit 3 while it settles)
pulzr-ports revert          undo it now
```

A layout:

```json
{"ports": [
  {"name": "wan", "role": "uplink"},
  {"name": "lan1", "role": "uplink",
   "addressing": {"mode": "static", "address": "10.9.0.2", "netmask": "255.255.255.0",
                  "gateway": "10.9.0.1", "dns": ["1.1.1.1"]}},
  {"name": "lan2", "role": "none", "vlans": [{"vid": 20, "role": "devices"}]}
]}
```

Over MQTT, `ports` answers with `status`, read-only, as `uplinks` and `dns`
do: the layout is the site's, and Pulzr Cloud shows it beside the gateway.

Each port and VLAN in `status` lists `addresses`: every IPv4 address on its
device, whichever netifd interface holds it, so the board's uplink port shows
its lease and the console's `192.168.61.1/24` and `169.254.61.1/16` together.
A LAN port has none of its own; the bridge's are in the `lan` report
(`address` and `addresses`). An uplink's `state` has `addresses` too, with
`address` the first of them. The console's interface readers
(`/api/network/status`, `/api/access/status`) report `addresses` beside
`address` the same way.
