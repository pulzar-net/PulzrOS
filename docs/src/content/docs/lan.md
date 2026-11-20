---
title: "LAN ports"
description: "A board with ports for devices, a router's LAN ports or a Pi's USB Ethernet adapter, serves those devices as a small network of its own: devlan."
---

A board with ports for devices, a router's LAN ports or a Pi's USB Ethernet
adapter, serves those devices as a small network of its own: `devlan`. The
first device is a PLC that keeps its own identity and its own connection to
Pulzar; the gateway is only its path.

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
| Route out | whichever uplink the metrics pick (ethernet, WiFi once it reaches the internet, cellular), masqueraded |

The ports form one bridge with port isolation, so devices on different ports
cannot reach each other, and the zone forwards nothing back into itself.
Devices behind a switch on one port can still reach each other through the
switch; the gateway never sees that traffic.

## What a device can reach

| Destination | `parkeze` (default) | `internet` |
|---|---|---|
| Pulzar, TCP 443 and 8883 | yes | yes |
| NTP, UDP 123 | yes | yes |
| DNS, on the gateway | yes | yes |
| Anything else out an uplink | no | yes |
| The console's sign-in, TCP 80, 443 and 8443 | yes | yes |
| SSH, anything else on the gateway | no | no |
| Other LAN devices | no | no |
| The management tunnel | no | no |

"Pulzar" is the domains of `PULZR_NET_URL` and `PULZR_MQTT_HOST`
(`parkeze.com` today). dnsmasq adds each address it answers for those names to
an nftables set, so the rule follows a move without anybody changing it. A
device that ignores the gateway's DNS and asks its own resolver reaches none
of Pulzar.

The console is open here so a laptop on a LAN port can configure the gateway,
at `https://<the gateway's address here>`, or `https://pulzr.local` over mDNS.
What a device reaches is the sign-in page; see [auth.md](/PulzrOS/auth.html).

The zone rejects rather than drops: this is our network, and a device refused
gives up in a second where one dropped retries for a minute.

Traffic out over cellular is billed like anything else on the SIM. The
`internet` policy is for devices that need it; the traffic report below says
which device spent what, on which uplink.

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
pulzr-lan links                           reload the uplinks' devices and addresses
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

`lan` is not part of `all`: it grows with the number of devices, and `all` has
to stay under the agent's 8KB answer.

### The report

```json
{
  "configured": true, "address": "192.168.64.1", "ports": ["eth1", "eth2"],
  "clients": [{
    "mac": "c2:6c:1d:d1:f7:b3", "ip": "192.168.64.50", "hostname": "plc-1",
    "reserved": "192.168.64.50", "policy": "parkeze", "online": true, "port": "eth1",
    "cellular": "allow", "cellularBlock": ["tcp:554"],
    "firstSeen": 1793051334, "lastSeen": 1793051821, "leaseExpires": 1793094533,
    "traffic": { "wan": { "txBytes": 6169, "rxBytes": 22131 },
                 "tunnel": { "txBytes": 2109, "rxBytes": 927 } }
  }],
  "forwards": [{ "port": 40000, "ip": "192.168.64.50", "dport": 8080, "expiresIn": 3598 }],
  "exposed": [{ "proto": "tcp", "port": 8080, "ip": "192.168.64.50", "dport": 80 }],
  "exposedOn": [{ "uplink": "wwifi", "address": "192.168.1.40" }],
  "journal": [{ "at": 1793051648, "op": "open", "port": 40000, "ip": "192.168.64.50",
                "dport": 8080, "seconds": 3600, "id": "<request id>" }]
}
```

- `port` is the LAN port the client is behind, from the bridge's software
  table (`brforward`), never `bridge fdb show`: on a DSA switch that dumps the
  hardware table too, which on the GL-SFT1200 takes six seconds a port under
  RTNL. Null until the client has sent something through the bridge.
- `firstSeen` and `lastSeen` are DHCP contact, kept across reboots and
  upgrades. A device answering ARP right now is `online`, and its `lastSeen`
  is now.
- `traffic` is per uplink, by the netifd interface that carried it (`wan`,
  `wwifi`, `wwan`, `usbwan`), and `tunnel` for a forward's traffic. The
  console's Cellular column is `wwan` and `usbwan` together. Counted after the
  firewall, so a refused attempt is not traffic, and since boot. It lives in
  PulzarOS's own nftables table, so a firewall reload does not zero it.
- `exposedOn` is where exposed ports answer now: each wired and WiFi
  uplink's address. A private one is behind a site router.
- `journal` is the last twenty forwards opened and closed, and ports exposed
  and removed (`op` `expose`, `unexpose`).

## The tunnel forward

The one forward a gateway makes: from the WireGuard management tunnel to one
device's TCP port, for between a minute and a day. It is how somebody on
Pulzar Cloud opens a PLC's own interface without the PLC holding a second
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
