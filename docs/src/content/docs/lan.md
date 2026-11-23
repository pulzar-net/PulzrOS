---
title: "LAN ports"
description: "A board with ports for devices, a router's LAN ports or a Pi's USB Ethernet adapter, serves those devices as a small network of its own: devlan."
---

A board with ports for devices, a router's LAN ports or a Pi's USB Ethernet
adapter, serves those devices as a small network of its own: `devlan`. The
first device is a PLC that keeps its own identity and its own connection to
Pulzr; the gateway is only its path.

A board without them is unchanged. Its one port has no role and never serves
DHCP; see [backhaul.md](/PulzrOS/backhaul.html).

## Turning it on for a board

In the board's `board.conf`:

```sh
PULZR_LAN_PORTS="lan1 lan2 lan3"     # the ports, by their Linux names
PULZR_FEATURES="${PULZR_FEATURES} lan"
```

A USB adapter also needs its driver in `PACKAGES_BOARD`:
`kmod-usb-net-rtl8152` for the common Realtek ones, `kmod-usb-net-asix-ax88179`
for ASIX, `kmod-usb-net-cdc-ether` for adapters that follow the standard. On a
Pi the adapter is `eth1`.

`PULZR_DEVLAN_IPADDR` is the gateway's address on it, `192.168.64.1` unless
the board says otherwise. The first boot builds the rest
(`feed/pulzr-lan/files/etc/uci-defaults/25-pulzr-lan`).

Those are the ports a gateway starts with. Which ports, and which VLANs,
serve devices after that is Network > Ports ([ports.md](/PulzrOS/ports.html)): any port
can be moved in or out of `br-devlan`, and a tagged VLAN can serve devices
behind a managed switch.

## What a device gets

| | |
|---|---|
| Address | DHCP from `.100` to `.199`, 12 hour leases, or a reservation |
| Router and DNS | the gateway |
| Route out | whichever uplink the metrics pick (ethernet, WiFi once it reaches the internet, cellular), masqueraded; never the management tunnel |
| The internet | by default, metered per device ([Metering](#metering)) |

The ports form one bridge with port isolation, so devices on different ports
cannot reach each other, and the zone forwards nothing back into itself.
Devices behind a switch on one port can still reach each other through the
switch; the gateway never sees that traffic.

## What a device can reach

| Destination | `internet` (default) | `parkeze` |
|---|---|---|
| Pulzr, TCP 443 and 8883 | yes | yes |
| NTP, UDP 123 | yes | yes |
| DNS, on the gateway | yes | yes |
| Anything else out an uplink | yes | no |
| The console's sign-in, TCP 80, 443 and 8443 | yes | yes |
| SSH, anything else on the gateway | no | no |
| Other LAN devices | no | no |
| The management tunnel | no | no |

"Pulzr" is the domains of `PULZR_NET_URL` and `PULZR_MQTT_HOST`
(`parkeze.com` today). dnsmasq adds each address it answers for those names to
an nftables set, so the rule follows a move without anybody changing it. A
device that ignores the gateway's DNS and asks its own resolver reaches none
of Pulzr.

The console is open here so a laptop on a LAN port can configure the gateway,
at `https://<the gateway's address here>`, or `https://pulzr.local` over mDNS.
What a device reaches is the sign-in page; see [auth.md](/PulzrOS/auth.html).

The zone rejects rather than drops: this is our network, and a device refused
gives up in a second where one dropped retries for a minute.

`internet` is the default: a device behind the gateway gets the internet
straight out the active uplink, as it would behind any router, and the gateway
meters it. `parkeze` narrows one device to the rows above, which is what
every device got before metering. In fw4 it is a `REJECT`
per device per uplink zone, between the Pulzr and NTP accepts and the zone's
`Allow-LAN-internet-<zone>`; `pulzr-lan apply` keeps it there, since an
upgrade re-adds the zone's rules at the end.

Traffic out over cellular is billed like anything else on the SIM. The
cellular rule below keeps a device off it; the report says which device
spent what, on which uplink.

## Cellular, per device

Each device is allowed onto cellular (the default), blocked from it, or
allowed except some ports: `tcp:554` or `udp:5000-5010`, at most sixteen.
It holds whatever the policy allows, and only on the cellular devices (`wwan`,
`usbwan`): over a wired or WiFi uplink the device reaches what its policy
says. A camera on `internet` with its stream blocked on cellular keeps
sending alarms through a failover and stops spending the SIM on video.
Refused, not dropped, as the zone does.

Matched by MAC in pulzr-lan's own table, on the cellular devices netifd
has now (the `cellular_if` set, reloaded on each uplink's hotplug).

## Managing it

On the gateway:

```
pulzr-lan status                          everything below, as JSON
pulzr-lan policy <mac> parkeze|internet
pulzr-lan reserve <mac> <ip> [<name>]     <name> also resolves, as <name>.lan
pulzr-lan unreserve <mac>
pulzr-lan cellular <mac> allow|block [tcp:<port>[-<port>] udp:...]
pulzr-lan forward <ip> <port> <seconds>
pulzr-lan unforward <tunnel port>
pulzr-lan expose tcp|udp <port> <ip> [<client port>]
pulzr-lan unexpose tcp|udp <port>
pulzr-lan address add|remove <a.b.c.d/nn> another subnet on the bridge
pulzr-lan address for <device ip>         one in a device's own subnet, probed free
pulzr-lan links                           reload the uplinks' devices and addresses
pulzr-lan scan                            scan the clients' management ports now
pulzr-lan save-usage                      save each client's totals for the next boot
```

In the console, Network > LAN (`lib/lan.uc`, `pages/network/Lan.tsx`): the
clients, each one's policy, reservation and cellular rule, the exposed ports,
and the open tunnel forwards. It sets the first four through the commands
above, audited as `lan.policy`, `lan.reserve`, `lan.cellular` and
`lan.expose`, so the `lan` op reports them like any other. It never opens or
closes a tunnel forward: that is the cloud's, over MQTT. The cloud opens no
exposed port: that is the site's, made at the gateway.

Over MQTT (`parkeze/gateway/<eui>/mgmt/request`, see `pulzr-mqtt-agent`):

| `op` | Fields | Answer |
|---|---|---|
| `lan` | | the status below |
| `lan-policy` | `mac`, `policy` | `{mac, policy}` |
| `lan-reserve` | `mac`, `ip`, optional `name`; no `ip` releases it | `{mac, ip, name}` |
| `lan-forward` | `ip`, `port`, `seconds` | `{port, ip, dport, expires}` |
| `lan-unforward` | `port` | `{port, closed}` |
| `lan-address` | `address` (`10.0.0.2/24`) and optional `remove: true`, or `for` (a device's address) | `{addresses, address}` |

`lan` is not part of `all`: it grows with the number of devices, and `all` has
to stay under the agent's 8KB answer.

### The report

```json
{
  "configured": true, "address": "192.168.64.1", "ports": ["eth1", "eth2"],
  "addresses": ["10.0.0.2/24"],
  "links": [{ "name": "eth1", "up": true, "speed": 100, "duplex": "full", "carrierChanges": 2 },
            { "name": "eth2", "up": false, "speed": null, "duplex": null, "carrierChanges": 0 }],
  "clients": [{
    "mac": "c2:6c:1d:d1:f7:b3", "ip": "192.168.64.50", "hostname": "plc-1",
    "reserved": "192.168.64.50", "policy": "internet", "online": true, "port": "eth1",
    "cellular": "allow", "cellularBlock": ["tcp:554"],
    "firstSeen": 1793051334, "lastSeen": 1793051821, "leaseExpires": 1793094533,
    "services": [22, 80],
    "traffic": { "wan": { "txBytes": 6169, "rxBytes": 22131 },
                 "tunnel": { "txBytes": 2109, "rxBytes": 927 } }
  }],
  "forwards": [{ "port": 40000, "ip": "192.168.64.50", "dport": 8080, "expiresIn": 3598 }],
  "exposed": [{ "proto": "tcp", "port": 8080, "ip": "192.168.64.50", "dport": 80 }],
  "exposedOn": [{ "uplink": "wwifi", "address": "192.168.1.40" }],
  "journal": [{ "at": 1793051648, "op": "open", "port": 40000, "ip": "192.168.64.50",
                "dport": 8080, "seconds": 3600, "id": "<request id>" }],
  "scannedAt": 1793051700,
  "usageEpoch": "3f2a9c1e-6921b5c4"
}
```

- `links` is each port in `br-devlan` and its link, read from sysfs
  (`carrier`, `speed`, `duplex`, `carrier_changes`), never through RTNL.
  `speed` and `duplex` are null without a link. `carrierChanges` counts every
  up and down since boot: a port that came up once reads 1 or 2, and one that
  keeps climbing is a cable or a device dropping its link.
- A client is anything that leased an address, holds a reservation, answers
  ARP or is in the bridge's table. The last alone, with an `ip` of null and no
  `firstSeen`, is a device on the wire that never asked for a lease: a camera
  with a static address on another subnet. At most eight of those are listed,
  so a LAN port cabled into a site switch cannot push the answer past the
  agent's 8 KB.
- `port` is the LAN port the client is behind, from the bridge's software
  table (`brforward`), never `bridge fdb show`: on a DSA switch that dumps the
  hardware table too, which on the GL-SFT1200 takes six seconds a port under
  RTNL. Null until the client has sent something through the bridge, and
  again once the bridge ages it out, five minutes after its last frame.
- `firstSeen` and `lastSeen` are DHCP contact, kept across reboots and
  upgrades. A device answering ARP right now is `online`, and its `lastSeen`
  is now. A client with no contact for a week is forgotten (`SEEN_KEEP`),
  unless it is reserved; Pulzr Cloud keeps its own record of it.
- Network > LAN lists clients heard from in the last hour (online, on the
  bridge, learned from their ARP) and configured ones, which stay while off:
  reserved, or an exposed port's target. **All** shows the rest. Pulzr
  Cloud's Devices on LAN uses the same hour.
- `traffic` is per uplink, by the netifd interface that carried it (`wan`,
  `wan_<port>`, `wwifi`, `wwan`, `usbwan`), and `tunnel` for a forward's
  traffic. The console's Cellular column is `wwan` and `usbwan` together.
  Counted after the firewall, so a refused attempt is not traffic. Running
  totals within `usageEpoch`; see [Metering](#metering). It lives in
  PulzrOS's own nftables table, so a firewall reload does not zero it.
- `exposedOn` is where exposed ports answer now: each wired and WiFi
  uplink's address. A private one is behind a site router.
- `journal` is the last twenty forwards opened and closed, and ports exposed
  and removed (`op` `expose`, `unexpose`).
- `services` is the management ports the client answered on at the last scan
  that reached it, and `scannedAt` when the last scan ran. A client no scan has
  reached has no `services`: unknown, not closed.

## Metering

Each device's internet use, per uplink, for a plan's data allowance. The
kernel counts (nftables: a dynamic set keyed on the device's address and the
uplink device, a counter on each element, after fw4 has filtered); nothing on
the gateway adds bytes up by hand. nlbwmon counts per device but not per
uplink, and which uplink carried the bytes is half the question.

`traffic` in the report is a running total per device within `usageEpoch`.
Pulzr Cloud adds up the differences between one report and the next, so
the gateway sends no extra message for metering: it is the `lan` report the
cloud already asks for. A total never goes backwards inside an epoch:

| Event | What happens |
|---|---|
| Reboot, `reboot` or a power button | `pulzr-lan`'s init stop (`STOP=10`, before the network goes) writes every device's totals to `/etc/pulzr/lan/usage.json`; the next boot's table starts from them under the same epoch. One flash write per shutdown. |
| Firmware upgrade | `pulzr-firmware pending` saves them the same way before sysupgrade, which kills services rather than stopping them; `/etc/pulzr/lan` is kept across the upgrade. |
| Power cut | Nothing was saved, so the next boot is a new epoch from zero. What moved since the cloud's last report, at most its polling interval, is not metered. |
| A device gets another address, or an address another device | The DHCP event (`pulzr-lan seen`) folds the old address's counters into its owner's total and deletes them from the kernel. |
| The table is remade by hand | A new epoch. |

The totals in RAM are `/var/run/pulzr/lan-usage/epoch` and `base.json`. The
flash copy exists only between a clean shutdown and the next boot, and a
start that finds the table already there (a stop that was not a shutdown)
deletes it, since the counters running are newer.

Wired and WiFi clients are metered alike: a WiFi access point serving devices
is a member of `br-devlan` (Radios > WiFi, `ATTACH`).

## The port scan

Which of SSH (22), telnet (23) and web (80, 443, 8080, 8443) each client
answers on, so the console offers a terminal or a web page only where one will
open. `pulzr-lan-scan` runs `pulzr-lan scan` every fifteen minutes, a minute or
two after a new lease, and a few minutes after boot.

It is meant to go unnoticed by the devices it asks:

- nmap, a TCP connect to each of the six ports, polite timing (`-T2`: one
  probe at a time, 0.4 s apart), one retry, and at most a minute a client.
- Only the clients the gateway can see on the devlan bridge now, by a complete
  ARP entry, never a sweep of the subnet. Bound to the bridge (`-e
  br-devlan`), so nothing is ever asked on an uplink.
- Not at all while the default route is cellular, or when there is none: the
  tunnel that would use the answer is not there, and the push would be billed.

A scan that finds what the last one did pushes nothing; one that finds a port
open or closed pushes `lan`. The result is kept in `/var/run`, so a reboot
forgets it and the first scan after boot says it again. A client gone a week
loses what was found on it.

The gateway's own ports are never scanned. Every board's six-hourly report
carries `listening`: the same six ports, for those something on the gateway
listens on beyond loopback, read from the kernel's socket table
(`pulzr-claim`). The console offers the gateway's Shell and Web UI by it.

## Devices with a static address

Plenty of devices come out of the box with a fixed address, such as a camera
at `10.0.0.112`, and never ask for a lease. They are a supported mode, end to
end, in three steps:

| Step | What happens | Who does it |
|---|---|---|
| Heard | The device's own ARP says its address; the gateway reads it off the bridge | the gateway, passively |
| Reached | The gateway takes an address in the device's subnet | somebody, one click |
| Used | Web UI, SSH, reservations and exposed ports, as for a leased client | as for any client |

**Heard.** The kernel drops ARP from a subnet the gateway has no address on,
so the neighbour table never sees such a device. A bridge-family nftables
table of pulzr-lan's own (`bridge pulzr_lan_learn`) reads every ARP that
arrives on a LAN port and keeps the sender's MAC and address for 30 minutes
(`wire4`, at most 512). Nothing is sent and no subnet is swept; ARP probes
from `0.0.0.0` are skipped. A client with no lease, reservation or neighbour
entry is reported with that address, `"learned": true`, and `onLan`: whether
any subnet of the LAN holds it.

**Reached.** A learned address never makes a route or a subnet on its own.
`pulzr-lan address for 10.0.0.112` (MQTT `lan-address` with `for`; the
console's **Add Subnet** on the client's row) gives the gateway an address in
the device's `/24`: from `.253` down, skipping the device's own, any address
heard on the wire and any that answers a duplicate-address probe
(`arping -D`, at most eight), so a device that is switched off is the only
collision left. `.254` and `.1` are left alone, being where a site's router
usually sits. A `/24` because factory defaults are; a device on a wider
subnet still reaches a `/24` inside it.

`pulzr-lan address add 10.0.0.2/24` does the same with an address of your
choosing. Either way it is kept in `network.devlan_extra`, a second interface
on `br-devlan`, so it survives reboots and upgrades. At most eight, from `/8`
to `/30`, and none that overlaps the LAN, another of them, an uplink's or the
tunnel's subnet, or the console, setup, USB or link-local networks. The
report lists them as `addresses`.

**Used.** A device there is treated like any other client: the same zone,
isolation, policy, cellular rules and counting, since every rule matches the
bridge rather than a subnet. It can be forwarded to through the tunnel (the
console's Web UI and SSH), reserved (the name resolves; no lease is served
there) and exposed. A subnet an exposed port points into cannot be removed
until the port goes. A forward, reservation or exposed port to an address on
no subnet of the LAN is refused with `<ip> is on no subnet of the LAN: add
one for it first`.

## Devices a codec drives (pulzr-ip)

A device that speaks its own protocol over IP instead of Pulzr's (an IP
camera's settings API) is driven by its device type's codec, which runs in
Pulzr, not here: it turns each command into `ip.http`, `ip.tcp` or `ip.udp`
requests (pulzr-protocol, "IP requests"), and pulzr-edge-ip, in every image
with LAN ports, makes them. Nothing on the gateway knows the device.

| | |
|---|---|
| Where | Only an address on a subnet `br-devlan` holds (the LAN, and any added for a device with a static address), never the gateway's own, the network or the broadcast address; the address is Pulzr's record of the device, never the codec's |
| Config | `/var/run/pulzr-edge/ip.toml`, generated at every start from `br-devlan`'s addresses; a change to `devlan` or `devlan_extra` restarts it |
| Limits | 30 s and 48 KiB a request; no redirects, no proxy; one device's requests in order |
| Log | The device and the request's name, never its contents: a device's login rides in them |

The binary is pulzr-edge built with its `ip` feature alone, as each add-on's
module is, so the image carries only that module: on mipsel (the Opal) 4.1 MB
raw and 1.2 MB in the image's squashfs (pulzr-edge 0.5.1's release build), in
the read-only image, nothing on the overlay. pulzr-edge with every module is
over 10 MB raw.

## The tunnel forward

The one forward a gateway makes: from the WireGuard management tunnel to one
device's TCP port, for between a minute and a day. It is how somebody on
Pulzr Cloud opens a PLC's own interface without the PLC holding a second
connection or the site opening anything.

`lan-forward` answers with a tunnel port, from 40000 to 40015, and `expires`,
the Unix time it closes (the report's `expiresIn` is the seconds left).
the cloud connects to the gateway's WireGuard address on that port and
reaches the device, which sees the connection come from the gateway's LAN
address. Only traffic arriving on `wg0` is forwarded: the same port on the SIM
address, the site network or anything else reaches nothing.

- **It closes on time.** The forward is an nftables element with a timeout,
  so the kernel removes it; nothing on the gateway has to remember to.
- **A session ends with it.** A connection through a forward is dropped the
  moment its port closes, by expiry or by `lan-unforward`.
- **A reboot closes every forward.** Nothing about one is on flash except its
  journal entry.
- **Only through the forward.** The tunnel cannot route to the LAN; `mgmt`
  forwards nothing but what the forward's DNAT marked.
- **Journalled**, like a setup AP raise: every open and close, with the
  request id, in `/etc/pulzr/lan/forwards.log`, kept across upgrades and
  reported in `lan`.

The table and the reasoning for keeping it out of fw4's are in the header of
`/usr/sbin/pulzr-lan`.

## Exposed ports

A port on a wired or WiFi uplink's own address, forwarded to one device for
good: a camera or a PLC the customer serves to the internet, through their
own router's forward to the gateway and their own name (Network > DNS,
Dynamic DNS; [features.md](/PulzrOS/features.html)). TCP or UDP, at most 32.

- **Wired and WiFi only.** Matched on the uplink's device and its address
  together (`uplink_in`: `wan`, `wan_<device>`, `wwifi`). Not on fw4's `wan`
  zone, which also holds `usbwan`, a cellular dongle, and the console's
  addresses on the same port. The tunnel and the SIM never reach one.
- **Never out cellular.** A connection through an exposed port is dropped
  rather than forwarded to a cellular device, so a failover does not carry
  a customer's stream on our SIM.
- **To a reserved address.** The device has to hold a reservation, and keeps
  it while exposed: moving or releasing it is refused until the port goes,
  or the port would follow whatever leased the address next.
- **Not the gateway's own ports**: TCP 22, 80, 443 and 8443, UDP 67 and 68.
- **Kept**, in UCI (`pulzr.expose_<proto>_<port>`), across reboots and
  upgrades; each one made and removed is in the journal.
- **Behind a site router**, the uplink's address is private and the page
  says so: the site router forwards the same port to the gateway's address,
  which Backhaul > Ethernet can make static from its lease.

The device sees the caller's real address: nothing is masqueraded. Replies
follow the main routing table, so an exposed port answers on whichever
uplink carries the default route; see the header of `/usr/sbin/pulzr-lan`.
fw4's `wan` zone forwards nothing, so `wan-forward.nft` adds one rule to it,
accepting what this table's DNAT marked.
