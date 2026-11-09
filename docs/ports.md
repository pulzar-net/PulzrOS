# Ports and VLANs

Each Ethernet port is an **uplink**, a **LAN** port for devices (the devlan
zone, [lan.md](lan.md)), or **unused**, and can carry tagged VLANs, each with
a role of its own. Network > Ports in the console, `parkeze-ports` on the
gateway.

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

`parkeze-ports render` writes it into network, firewall and dhcp:

| | |
|---|---|
| An uplink | a netifd interface in the wan zone: `wan` for the board's uplink port untagged, `wan_<device>` for any other (`wan_lan1`, `wan_wan_20`). A link keeps its name, its place in the order and its tracking when another is added. |
| A LAN link | a member of `br-devlan`, isolated from the other members |
| A VLAN | a `vlan_<port>_<vid>` 8021q device |
| The console's `192.168.61.1` and `169.254.61.1` | on the board's uplink port while it is an uplink, else the first port that is one, and nowhere when none is: a LAN port already answers at `192.168.64.1` with DHCP |
| dnsmasq | never answers on an uplink's device |
| parkeze-uplinks | a new wired uplink is tracked and goes after the last wired one in the order |

The layout and each uplink's addressing live in `/etc/config/parkeze`
(`port_<name>`, `vlan_<name>_<vid>`). `19-parkeze-ports` seeds it from the
board, keeping whatever `network.wan` had, before `20-parkeze-network`
rebuilds the defaults; `29-parkeze-ports` writes it back over them.

## Kept only once confirmed

A port change can cut off whoever makes it: the laptop on the LAN jack that
becomes an uplink, or the tunnel on the uplink that becomes a LAN port when
the change came through Pulzr Net. So:

1. `set` keeps the configuration it replaces on flash
   (`/etc/parkeze/ports/rollback`), applies the new one, and starts a timer.
2. The page confirms by reaching the gateway again, no sooner than 15 seconds
   after the reload finished (`confirm` refuses earlier: the network is still
   moving).
3. Nothing confirms within 90 seconds: the old configuration comes back. A
   reboot inside the window undoes it at boot, before the network starts
   (`/etc/init.d/parkeze-ports`, START=11).

A second change inside the window keeps the first snapshot, the one known to
work. At least one port has to stay an uplink or a LAN port untagged, so a
plain cable always finds the console.

Checked on the Opal, 2026-11-08: `wan`, which carried the tunnel, made unused
and not confirmed; the gateway was unreachable, undid it 99 seconds later and
was back on the tunnel 17 seconds after that.

## Managing it

```
parkeze-ports status          every port, its role, VLANs, addressing, a pending change
parkeze-ports set <file>|-    a whole layout as JSON; undone unless confirmed
parkeze-ports confirm         keep it (exit 3 while it settles)
parkeze-ports revert          undo it now
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
do: the layout is the site's, and Pulzr Net shows it beside the gateway.
