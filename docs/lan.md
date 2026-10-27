# LAN ports

A board with ports for devices, a router's LAN ports or a Pi's USB Ethernet
adapter, serves those devices as a small network of its own: `devlan`. The
first device is a PLC that keeps its own identity and its own connection to
Parkeze; the gateway is only its path.

A board without them is unchanged. Its one port has no role and never serves
DHCP; see [backhaul.md](backhaul.md).

## Turning it on for a board

In the board's `board.conf`:

```sh
PARKEZE_LAN_PORTS="lan1 lan2 lan3"     # the ports, by their Linux names
PARKEZE_FEATURES="${PARKEZE_FEATURES} lan"
```

A USB adapter also needs its driver in `PACKAGES_BOARD`:
`kmod-usb-net-rtl8152` for the common Realtek ones, `kmod-usb-net-asix-ax88179`
for ASIX, `kmod-usb-net-cdc-ether` for adapters that follow the standard. On a
Pi the adapter is `eth1`.

`PARKEZE_DEVLAN_IPADDR` is the gateway's address on it, `192.168.64.1` unless
the board says otherwise. The first boot builds the rest
(`feed/parkeze-lan/files/etc/uci-defaults/25-parkeze-lan`).

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
| Parkeze, TCP 443 and 8883 | yes | yes |
| NTP, UDP 123 | yes | yes |
| DNS, on the gateway | yes | yes |
| Anything else out an uplink | no | yes |
| The console, SSH, anything else on the gateway | no | no |
| Other LAN devices | no | no |
| The management tunnel | no | no |

"Parkeze" is the domains of `PARKEZE_NET_URL` and `PARKEZE_MQTT_HOST`
(`parkeze.com` today). dnsmasq adds each address it answers for those names to
an nftables set, so the rule follows a move without anybody changing it. A
device that ignores the gateway's DNS and asks its own resolver reaches none
of Parkeze.

The zone rejects rather than drops: this is our network, and a device refused
gives up in a second where one dropped retries for a minute.

Traffic out over cellular is billed like anything else on the SIM. The
`internet` policy is for devices that need it; the traffic report below says
which device spent what, on which uplink.

## Managing it

On the gateway:

```
parkeze-lan status                          everything below, as JSON
parkeze-lan policy <mac> parkeze|internet
parkeze-lan reserve <mac> <ip> [<name>]     <name> also resolves, as <name>.lan
parkeze-lan unreserve <mac>
parkeze-lan forward <ip> <port> <seconds>
parkeze-lan unforward <tunnel port>
```

In the console, Network > LAN (`lib/lan.uc`, `pages/network/Lan.tsx`): the
clients, each one's policy and reservation, and the open forwards. It sets a
policy and a reservation through the commands above, audited as `lan.policy`
and `lan.reserve`, so the `lan` op reports them like any other. It never opens
or closes a forward: that is net-api's, over MQTT.

Over MQTT (`parkeze/gateway/<eui>/mgmt/request`, see `parkeze-mqtt-agent`):

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
    "reserved": "192.168.64.50", "policy": "parkeze", "online": true,
    "firstSeen": 1793051334, "lastSeen": 1793051821, "leaseExpires": 1793094533,
    "traffic": { "wan": { "txBytes": 6169, "rxBytes": 22131 },
                 "tunnel": { "txBytes": 2109, "rxBytes": 927 } }
  }],
  "forwards": [{ "port": 40000, "ip": "192.168.64.50", "dport": 8080, "expiresIn": 3598 }],
  "journal": [{ "at": 1793051648, "op": "open", "port": 40000, "ip": "192.168.64.50",
                "dport": 8080, "seconds": 3600, "id": "<request id>" }]
}
```

- `firstSeen` and `lastSeen` are DHCP contact, kept across reboots and
  upgrades. A device answering ARP right now is `online`, and its `lastSeen`
  is now.
- `traffic` is per uplink, by the netifd interface that carried it (`wan`,
  `wwifi`, `wwan`, `usbwan`), and `tunnel` for a forward's traffic. The
  console's Cellular column is `wwan` and `usbwan` together. Counted after the
  firewall, so a refused attempt is not traffic, and since boot. It lives in
  ParkezeOS's own nftables table, so a firewall reload does not zero it.
- `journal` is the last twenty forwards opened and closed.

## The tunnel forward

The one forward a gateway makes: from the WireGuard management tunnel to one
device's TCP port, for between a minute and a day. It is how somebody on
parkeze.net opens a PLC's own interface without the PLC holding a second
connection or the site opening anything.

`lan-forward` answers with a tunnel port, from 40000 to 40015. gateway-link
connects to the gateway's tunnel address on that port and reaches the device,
which sees the connection come from the gateway's LAN address.

- **It closes on time.** The forward is an nftables element with a timeout,
  so the kernel removes it; nothing on the gateway has to remember to.
- **A session ends with it.** A connection through a forward is dropped the
  moment its port closes, by expiry or by `lan-unforward`.
- **A reboot closes every forward.** Nothing about one is on flash except its
  journal entry.
- **Only through the forward.** The tunnel cannot route to the LAN; `mgmt`
  forwards nothing but what the forward's DNAT marked.
- **Journalled**, like a setup AP raise: every open and close, with the
  request id, in `/etc/parkeze/lan/forwards.log`, kept across upgrades and
  reported in `lan`.

The table and the reasoning for keeping it out of fw4's are in the header of
`/usr/sbin/parkeze-lan`.
