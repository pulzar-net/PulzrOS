# Backhaul and management paths

A Pulzar gateway has two uplinks and two management paths, and the difference
between them is money.

## The uplinks

| | Ethernet | Cellular |
|---|---|---|
| Cost | free | billed per megabyte |
| Enabled by default | **yes** | **yes** |
| Operator-configurable in the console | **no** | yes (APN, on/off) |
| Route metric | 10 | 20 (`wwan`), 21 (`usbwan`) |

Both are defined in `feed/pulzr-base/files/etc/uci-defaults/20-pulzr-network`,
except `usbwan`, which `pulzr-usb-cellular` adds on boards that have it.

On a board with the `failover` feature these metrics are pulzr-uplinks',
from the order the site chooses; see "Failover" below.

### Cellular adapters

Cellular is one of two netifd interfaces, depending on how the adapter talks
to the gateway:

| Interface | Adapter | Driver | Console shows |
|---|---|---|---|
| `wwan` | modem on QMI | `qmi_wwan` | QMI modem |
| `wwan` | modem on MBIM | `cdc_mbim` | MBIM modem |
| `wwan` | modem with only AT ports; data over PPP (`ppp-wwan`) | `option` | AT modem |
| `wwan` | Huawei stick in modem mode | `huawei_cdc_ncm`, `option` | AT modem |
| `usbwan` | HiLink dongle (Huawei E3372h, ZTE) | `cdc_ether`, `rndis_host`, `cdc_ncm` | HiLink dongle |
| `usbwan` | phone sharing its data over USB | `rndis_host`, `cdc_ncm`, `ipheth` | Tethered phone |

`wwan` is `proto modemmanager` whatever the modem speaks: ModemManager picks
QMI, MBIM or AT, and the proto runs pppd when the bearer says PPP.
`pulzr-modem-detect` binds it by the modem's sysfs path, which is the same
for all three, and reads the kind off the control ports ModemManager lists.

`usbwan` is a DHCP client. A HiLink dongle or a phone runs the modem, a NAT
and a DHCP server of its own, and shows the gateway a USB Ethernet port, so
ModemManager has nothing to talk to. `pulzr-usb-cellular` binds `usbwan` to
whichever device appeared: one on those four drivers, not a port the board
names (`PULZR_PORT_IFACE`, `PULZR_LAN_PORTS`) or a bridge member, and with
no control port on the same USB device. One with a control port is a modem
ModemManager drives as `wwan`. Huawei and ZTE devices, and any the kernel flags
as a WWAN function, read as HiLink; anything else as a phone. Only the label
depends on that guess.

What is supported where: the RAK images carry `qmi_wwan` only, for the modem
soldered to their one USB port. The Pis and the Opal carry every row above
(`PACKAGES_USB_CELLULAR` in `boards/common/board.conf`), with `usb-modeswitch`
for a dongle that first appears as a CD-ROM. An iPhone needs `usbmuxd` to pair:
unlock it and tap Trust when it asks, with Personal Hotspot on.

None of the `usbwan` rows has been tried on hardware, and neither have MBIM or
AT modems; QMI is the RAK's and the one that has.

### A tethered link is cellular

`usbwan` is a DHCP lease on an Ethernet device, which is exactly what the wired
uplink is, and nothing about the device says it is billed. Every rule here that
keeps traffic off the SIM treats it as cellular anyway, through one list:
`/usr/share/pulzr/cellular.sh` names `wwan` and `usbwan`, and nothing names
`wwan` alone any more.

| | `usbwan` |
|---|---|
| Route metric | 21: behind wired, an open WiFi and the modem |
| Management tunnel | refused unless `PULZR_WIREGUARD_ALLOW_CELLULAR` (`pulzr-wireguard-route`) |
| LoRaWAN uplinks | refused when `pulzr.lorawan.allow_cellular` is 0 (`pulzr-lora-route`) |
| `pulzr-backhaul-check` | the cellular path |
| Traffic | the Cellular column on Network > LAN; `pulzr-cellular-usage` |
| Report | `modemPresent`, `modemModel` and `modemKind`, no `simIccid`; the cloud keeps `modemKind` once its report handler lists it |
| "Use cellular as a backhaul" | turns it off with `wwan` |
| Firewall zone | wan, not cellular |

The zone is the one exception, and it is about who is on the far side, not
about the bill. The cellular zone admits SSH and the console because the far
side of a 1NCE SIM is the carrier network the cloud reaches through. The far
side of `usbwan` is a dongle's or a phone's NAT, a box nobody here runs, and
the cloud cannot reach the gateway through it. So `cellular_ip` in
`pulzr-gateway-facts` stays `wwan`'s.

A dongle in HiLink mode has no SIM ModemManager can read, so the console and
the report have the adapter's kind and the name its USB descriptor gives, and
no ICCID, operator or signal. The dongle's own page (usually 192.168.8.1) has
them.

What is knowingly wrong: a plain USB Ethernet adapter that speaks CDC, plugged
into a USB port as something other than a LAN port, is taken for a modem and
counted billed. That is the safe direction.

### Ethernet is configurable where you stand

Ethernet is the wired backhaul. It comes up on DHCP, it is the path the
WireGuard management tunnel rides, and it is how a wired site is managed. It is
on by default.

There can be more than one. Any port, or a VLAN on one, can be an uplink
([ports.md](ports.md)): `wan` for the board's uplink port, `wan_<device>` for
any other. Each takes the place in pulzr-uplinks' order its wired kind
does, is tracked as `wan` always was, and the tunnel and LoRa routing take
the first usable one (`/usr/share/pulzr/wired.sh`).

Backhaul > Ethernet sets each one to DHCP or to a static address, gateway and
DNS. This used to be read-only, on the reasoning that the uplink was
Pulzar Cloud's to decide. That broke the one case it mattered for: a site whose
network needs a static address is a site where the gateway cannot reach
Pulzar Cloud at all until somebody standing there says so, and that person had
no way to.

Two properties make it safe to offer:

- **A change that cuts somebody off comes back.** Addressing is applied the
  way a port change is, through `pulzr-ports set`: kept only once the page
  reaches the gateway again, undone after 90 seconds otherwise. Somebody
  working through Pulzar Cloud on the uplink the tunnel rides is the one a wrong
  static address would have stranded. A static address inside the console's,
  link-local, the LAN's, the setup AP's or the USB port's subnet is refused,
  as are two uplinks on one subnet.
- **The tunnel follows on its own.** Bringing a wired uplink up fires the
  tunnel's hotplug handler, which restarts it over the new route, and the
  report, which tells Pulzar Cloud the gateway is wired.

The addressing is kept with the port in `/etc/config/pulzr`, not only in
`network.<iface>`, so a sysupgrade, which rebuilds `network.wan` as DHCP,
no longer drops a static address.

> An earlier version shipped ethernet *disabled* by default, on the reasoning
> that a gateway should not put itself on an unassessed network. That was the
> wrong trade: the first thing anyone does with a new gateway is plug it in.

### WiFi counts once it reaches the internet

A joined WiFi network (`wwifi`, joined from the console) sits between the two:
free like ethernet, so preferred to cellular, at metric 15 — but only once
`pulzr-wifi-uplink` has seen it reach the internet.

A guest network hands out a lease and a default gateway before anybody has
signed in to it, and netifd calls that interface up. Before this check, that
was enough: the WiFi beat cellular for every packet, and the tunnel and the
LoRa routing both pinned themselves to it — all of it into a network that
answers nothing but its own sign-in page.

So the check asks, out of the WiFi device and nowhere else, for a URL that
answers 204 when the internet is there. It runs when the link comes up and once
a minute after (free: the WiFi is not billed), and its answer is one of:

| Answer | Meaning | Metric | Tunnel and LoRa may use it |
|---|---|---|---|
| `open` | 204 (or an empty 200) | 15 | yes |
| `portal` | a redirect or a page, a DNS answer with a private address, or an intercepted certificate | 30 | no |
| `offline` | no answer | 30 | no |
| `unchecked` | not asked yet, or the answer is about another network | 30 (as joined) | no |

Two such URLs, Google's and Cloudflare's, and the WiFi is judged only when both
fail: one blocked host, or a DNS filter refusing one name, used to cost the
uplink and set `roam()` looking elsewhere. When neither answers over HTTP, an
HTTPS request to Cloudflare's settles the rest: a certificate that verifies is
the internet with port 80 shut (open); one that does not is somebody in the
middle (portal). A portal that drops the probe instead of redirecting it still
answers the probe's name with its own private address, which also makes it a
portal; the address is kept as `hijack` for the sign-in proxy.

For anything not open the answer keeps the step that failed (`step`, `host`,
`detail`; the list is in `pulzr-wifi-uplink`'s header): no gateway or no DNS
server in the lease, the WiFi's DNS servers not answering (which ones), the
connection refused or timing out, no HTTP answer, an unexpected status. Each
change is logged once, and the console's WiFi page says it in one sentence.
The answer names the SSID it is about: a join or a roam no longer inherits the
last network's verdict.

Metric 30 rather than no route: the check needs one to send its own request out
of the radio, and behind both other uplinks nothing picks it.

The probe's name is asked of the WiFi's own DNS servers, on a socket bound to
the WiFi device (`pulzr-wifi-resolve`), and the sign-in proxy resolves the
same way. Not the gateway's resolver: it may ask over cellular and get the real
address, where a portal that hijacks DNS answers with its own. Not `nslookup`
against the WiFi's servers either: with the WiFi at metric 30 the route to them
is the SIM's, which is how USCGuest's OpenDNS was first asked over cellular.
And not a host route to those servers, which would move every lookup the
gateway makes onto a captive WiFi and send MQTT and reports to the portal. A change of
answer re-applies the tunnel and LoRa routing and sends a report, so
Pulzar Cloud shows `wifiUplink` beside the gateway. `roam()` treats `portal` and
`offline` as down, except while somebody is signing in (see access.md). A join
from the console restarts its clock and holds it off for five minutes, as a
switch does: the clock used to carry on from the network before, so a gateway
that had sat behind a guest portal was moved back to it within a minute of
being joined to eduroam. Each switch (from, to, the failing step, how long it
waited) is kept in `/var/run/pulzr/wifi-roams.json`, the last ten, which the
console shows while the gateway is still on the network it moved to.

### Cellular comes back on its own

`pulzr-cellular-watchdog` keeps the cellular link carrying traffic. It was
written for two 1NCE outages, each of which left a gateway offline with
nothing on it that would ever try again.

**A link that carries nothing.** 1NCE re-creates the session every 24 hours.
On 2026-10-23 the Osbourne gateway sent zero bytes over the new one for a day
while netifd and ModemManager both called the link fine.

**A link nobody brings back.** A connectivity reset made while the network is
refusing the SIM left a 0.1.0 gateway offline for good. Two things give up, one
on top of the other:

- **netifd.** ModemManager's `10-report-down` bounces `wwan` once. If
  registration or connect fails in that one setup, OpenWrt's modemmanager proto
  calls `proto_block_restart` and netifd never tries `wwan` again.
- **The modem.** A refused attach can come back with cause #8, "EPS and
  non-EPS services not allowed". After that the modem treats the SIM as invalid
  until it is switched off, and searches in emergency-only mode forever.
  Re-enabling the SIM at 1NCE, `ifup` and a ModemManager disable/enable all
  leave it there. A modem reset clears it.

When the network answers straight away, `10-report-down` alone recovers in
about 15 seconds. It takes a refusal longer than that one retry.

Once a minute the watchdog reads netifd's status and ModemManager's state, and
acts when:

| Seen for | State | Does |
|---|---|---|
| 2 min | `wwan` down, modem registered, disabled or gone | `ifup`; retries 1, 2, 4 min, up to 30 |
| 5 min | `wwan` down, modem not registered | modem reset, then the row above; resets 5, 10, 20 min, up to 30 |
| 2 min | `wwan` up, modem has no bearer | `ifup` |
| 10 min | `wwan` still setting up | `ifup` |
| 5 min | `wwan` up and connected, receive counter not growing | probe out of the cellular device; if that fails, `ifup`, then a modem reset, then a reboot, 5 min apart |
| 30 min | `wwan` down | reboot |

A reboot happens only when the gateway has been up six hours and nothing
reaches Pulzar Cloud, and the uplink buffer writes its queue to the card first.
The traffic row is skipped while the wired tunnel is up, because a SIM behind
ethernet is silent by design. Nothing happens while cellular is turned off in
the console (`network.wwan.disabled`) or there is no modem. A HiLink dongle or
a phone on `usbwan` is outside it: the device runs its own connection, and the
gateway's half is a DHCP lease netifd renews. The probe is the
only thing that spends data: one TCP connect, about 700 bytes, per five minutes
of silence.

The proto's own `force_connection` is not used. It covers registration and
connect but not the other failures that block, and re-running setup does
nothing for a modem that has written the SIM off.

`scripts/test-cellular-watchdog.sh` drives all of it against stubs, in CI.

### Failover

The metrics alone fail over only when netifd takes an interface down. A cable
to a site router whose own internet is gone keeps its carrier and its lease,
so `wan` stays at metric 10 and everything goes into it while the SIM behind
it works. On a board with `failover` (the Opal), `pulzr-uplinks` fixes that:

| | |
|---|---|
| Metric | 10, 20, 30, 40 by place in the order; 100 plus the same step once tracking has seen it fail |
| Tracking | a ping out of the uplink's own device (`ping -I`) to each target in turn, any answer counts |
| Default targets | 1.1.1.1, 8.8.8.8, every 10 s |
| Down | after 3 misses in a row |
| Back | after 3 answers in a row |
| Tracked by default | Ethernet |
| Cellular | untracked unless turned on: a ping every 10 s is about 40 MB a month |
| WiFi | pulzr-wifi-uplink's portal check is its health; it calls `pulzr-uplinks apply` instead of setting its own metric |
| Settings | `pulzr.uplinks` in UCI, kept across a sysupgrade |

A failed uplink keeps its route, at the back, because the next probe has to
leave through it. An uplink with no link, or no longer tracked, loses its
tracked state and comes back unchecked, which counts as healthy: waiting for
proof would hold a fresh cable back for half a minute after every boot.

When an uplink goes down or comes back, the tunnel and LoRa routing are
re-applied and a report is sent. `pulzr-wireguard-route` asks
`pulzr-uplinks usable wan` before pinning the tunnel to the cable, so a
dead cable moves the tunnel to the WiFi where there is one, and otherwise
leaves it waiting, as unplugging would.

Not mwan3: it is policy routing with fwmarks of its own, and the tunnel and
LoRa routing already confine their traffic with fwmark rules. And not load
balancing: it splits one site's connections over two public addresses and
spends the SIM on traffic a cable would carry free.

`scripts/test-router.sh` walks it through a failover and back, in CI.

### Nothing is accepted from the wan zone

This is the rule that makes a wired backhaul safe, and it is worth stating
plainly because it is the whole of the argument:

**The gateway's console, SSH and API are not reachable from the uplink.** The
wan zone's input policy is `DROP` — not on a high port, not "only from the LAN
side of their router", not at all.

`DROP` rather than `REJECT`: a rejection answers with an ICMP error and so
confirms something is listening. On a device whose security posture is "you
cannot reach the management plane from the internet", staying silent under a
scan is worth the slightly worse debuggability.

Management works the other way round. The gateway *originates* a WireGuard
tunnel to the Pulzar Cloud hub, and the cloud reaches it back down that
tunnel. No inbound port on the uplink is ever needed or opened.

## The management paths

```
                    ┌──────────────────┐
                    │   Pulzar Cloud    │
                    └────────┬─────────┘
                             │
                 ┌───────────┴───────────┐
                 │                       │
        ┌────────▼────────┐    ┌─────────▼─────────┐
        │  WireGuard hub  │    │  cellular VPN     │
        │  (cloud)        │    │  (cloud)          │
        └────────┬────────┘    └─────────┬─────────┘
                 │  free                 │  metered
        ┌────────▼────────┐    ┌─────────▼─────────┐
        │  wg0            │    │   wwan0 (SIM)     │
        │  via eth0 ONLY  │    │                   │
        └─────────────────┘    └───────────────────┘
                        gateway
```

The cloud chooses between them:

1. `mgmt_host`, if an operator pinned one.
2. The gateway's tunnel address, if the hub has had a handshake from it
   recently.
3. The SIM's address.

## The management tunnel

Plain kernel WireGuard, hub-and-spoke. There is no mesh and no coordination
server, and each gateway has one peer — the hub — at a single `/32`.

**Which hub.** The cloud picks the hub at enrolment and the gateway takes
whatever endpoint, hub key and hub address the answer gives, so nothing here
differs by organization. A gateway keeps the hub host it was given: one
enrolled before the rename may name `wg.net.parkeze.com:51820`, and that name
keeps answering.

**Enrollment.** The gateway generates its keypair on first start
(`/etc/pulzr/wireguard/`, private half 0600) and only the public half ever
leaves it. Once adopted, `pulzr-wireguard-enroll` posts that key to
`/api/v1/gateway-ops/wireguard/enroll`, proving which gateway it is with the
claim secret exactly as `/claim/poll` does, and gets back its tunnel address,
the hub's endpoint and the hub's public key. It retries in the background until
Pulzar Cloud answers, so it works the same for a gateway adopted online, one
adopted from a signed offline bundle that later gets internet, and one whose
key has changed. The keypair survives firmware upgrades (`keep.d`).

**Why not netifd's `proto wireguard`.** It keeps the private key in
`/etc/config/network`, which is world-readable. `pulzr-wireguard` creates
`wg0` itself and hands the kernel the key file.

**Who may reach a gateway on the tunnel.** `wg0` is its own firewall zone,
`mgmt`: input DROP, forward DROP, no masquerade, and one rule accepting tcp
22/80/443. No source match is needed — WireGuard only accepts a packet whose
inner source is in the sending peer's allowed IPs, and the one peer is the hub.
There is no forwarding, so the tunnel reaches the gateway and nothing behind
it: a customer's site network is not ours to expose.

The one exception is on a board with LAN ports: a forward to one device's TCP
port on the gateway's own LAN, opened on request and closed by the kernel when
it expires. See [lan.md](lan.md). The site's network is never behind it.

## The tunnel does not run over cellular by default

`PULZR_WIREGUARD_ALLOW_CELLULAR` is `"0"` on every board today, and turning
it on is a real option, not a hard constraint — but off is the right default.

**Why.** Not primarily cost, though a tunnel left alone would keep itself
alive over whatever route it finds — a keepalive every 25 seconds, forever,
which is negligible against a SIM's allowance either way. The real reason is
that a cellular gateway is already reachable: the cloud holds an OpenVPN
tunnel open into the SIM provider's CGNAT'd network, and every SIM answers on
a fixed address inside it (see "The management paths" above). WireGuard over
the same SIM to reach the same box would be a second management path doing the
first one's job.

**How.**

1. `wg0` carries WireGuard's native `fwmark` (`0x9700`), which marks the
   *encrypted outer* UDP it sends to the hub — the traffic that must be
   confined — rather than anything that travels inside `wg0`.

2. `pulzr-wireguard-route` puts a routing rule for that mark ahead of the
   main table, pointing at table 97, which contains the wired default route and
   nothing else.

3. A second rule at a lower priority makes marked packets **unreachable**. This
   is the part that matters: without it, a marked packet falls through to the
   main table when table 97 is empty and leaves over cellular — silently, and
   exactly in the situation the whole scheme exists to prevent.

The service refuses to bring the tunnel up if the rules did not install.

**What it means operationally.** When ethernet drops, the hub stops hearing
the gateway and its handshake goes stale. That is the designed behavior, not a
fault: Pulzar Cloud sees it and manages the gateway over the SIM instead. A
cellular-only gateway simply never completes a handshake, at no cost — its
packets have no route. The one thing that can escape is the DNS lookup for the
hub's name when the tunnel starts, a few bytes.

## Seeing which path works, for free

`GET /api/v1/gateway-ops/<eui>/backhaul` answers entirely from what the cloud
side already knows — the hub's last handshake with the gateway, and 1NCE.
Neither costs the gateway a byte, so the console can poll it and a wall display
can sit on it all day.

The obvious implementation of "is my gateway reachable" is to ping it. On this
fleet the obvious implementation is the expensive one. If you extend that
endpoint, extend it from an API that already knows.

`pulzr-backhaul-check` on the device follows the same rule: the wired path is
tested from the kernel's last WireGuard handshake (free), and the cellular path
only asks
whether a TCP connection to Pulzar Cloud completes — no TLS, no certificate
chain. That is about 700 bytes, against roughly 6KB for an HTTPS GET to a health
endpoint. It is not the 200 of a bare handshake because nothing on the image can
stop there: BusyBox `nc` is the minimal build without `-z`, and there is no
ucode socket module, so curl connects in plain HTTP to the HTTPS port and the
answer is whether the connection was made. It only tests cellular at all when
the wired path is already known to be down.

The probe host comes from `PULZR_NET_URL`. It used to be a literal
`Pulzar Cloud`, which no longer resolves, and the `nc -z` it ran never worked on
this image either — so until this was fixed the cellular path could not test as
up on any gateway.

### "Online" on the claim screen is a different question

Before adoption there is no tunnel, so "manageable" is false for every gateway
and says nothing about whether it can reach us. `pulzr-claim status` answers
the unadopted case from its own polling instead: each register and poll attempt
records whether Pulzar Cloud answered, and `online` is true if one did within the
last two hours. No extra bytes — the claim loop was making those requests anyway.
Once adopted, `online` goes back to `pulzr-backhaul-check`.
