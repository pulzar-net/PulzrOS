# Backhaul and management paths

A Parkeze gateway has two uplinks and two management paths, and the difference
between them is money.

## The uplinks

| | Ethernet | Cellular |
|---|---|---|
| Cost | free | billed per megabyte |
| Enabled by default | **yes** | **yes** |
| Operator-configurable in the console | **no** | yes (APN, on/off) |
| Route metric | 10 | 20 (`wwan`), 21 (`usbwan`) |

Both are defined in `feed/parkeze-base/files/etc/uci-defaults/20-parkeze-network`,
except `usbwan`, which `parkeze-usb-cellular` adds on boards that have it.

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
`parkeze-modem-detect` binds it by the modem's sysfs path, which is the same
for all three, and reads the kind off the control ports ModemManager lists.

`usbwan` is a DHCP client. A HiLink dongle or a phone runs the modem, a NAT
and a DHCP server of its own, and shows the gateway a USB Ethernet port, so
ModemManager has nothing to talk to. `parkeze-usb-cellular` binds `usbwan` to
whichever device appeared: one on those four drivers, not a port the board
names (`PARKEZE_PORT_IFACE`, `PARKEZE_LAN_PORTS`) or a bridge member, and with
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
`/usr/share/parkeze/cellular.sh` names `wwan` and `usbwan`, and nothing names
`wwan` alone any more.

| | `usbwan` |
|---|---|
| Route metric | 21: behind wired, an open WiFi and the modem |
| Management tunnel | refused unless `PARKEZE_WIREGUARD_ALLOW_CELLULAR` (`parkeze-wireguard-route`) |
| LoRaWAN uplinks | refused when `parkeze.lorawan.allow_cellular` is 0 (`parkeze-lora-route`) |
| `parkeze-backhaul-check` | the cellular path |
| Traffic | the Cellular column on Network > LAN; `parkeze-cellular-usage` |
| Report | `modemPresent`, `modemModel` and `modemKind`, no `simIccid`; net-api keeps `modemKind` once its report handler lists it |
| "Use cellular as a backhaul" | turns it off with `wwan` |
| Firewall zone | wan, not cellular |

The zone is the one exception, and it is about who is on the far side, not
about the bill. The cellular zone admits SSH and the console because the far
side of a 1NCE SIM is the carrier network gateway-link reaches through. The far
side of `usbwan` is a dongle's or a phone's NAT, a box nobody here runs, and
gateway-link cannot reach the gateway through it. So `cellular_ip` in
`parkeze-gateway-facts` stays `wwan`'s.

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

The console can set it to DHCP or to a static address, gateway and DNS. This
used to be read-only, on the reasoning that the uplink was parkeze.net's to
decide. That broke the one case it mattered for: a site whose network needs a
static address is a site where the gateway cannot reach parkeze.net at all until
somebody standing there says so, and that person had no way to.

Two properties make it safe to offer:

- **It never cuts off the person making the change.** Only `network.wan` is
  touched. The console (`192.168.61.1`) and link-local addresses are separate
  interfaces on the same port, so a wrong static address costs the uplink, not
  the page. A static address inside either of those subnets is refused. That is
  also why there is no timed rollback: the person who can fix it is still
  connected.
- **The tunnel follows on its own.** Bringing `wan` up fires the tunnel's
  hotplug handler, which restarts it over the new route, and the report, which
  tells parkeze.net the gateway is wired.

> An earlier version shipped ethernet *disabled* by default, on the reasoning
> that a gateway should not put itself on an unassessed network. That was the
> wrong trade: the first thing anyone does with a new gateway is plug it in.

### WiFi counts once it reaches the internet

A joined WiFi network (`wwifi`, joined from the console) sits between the two:
free like ethernet, so preferred to cellular, at metric 15 — but only once
`parkeze-wifi-uplink` has seen it reach the internet.

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
| `open` | 204 | 15 | yes |
| `portal` | a redirect or a page | 30 | no |
| `offline` | no answer | 30 | no |
| `unchecked` | not asked yet | 30 (as joined) | no |

Metric 30 rather than no route: the check needs one to send its own request out
of the radio, and behind both other uplinks nothing picks it.

The probe's name is asked of the WiFi's own DNS servers, on a socket bound to
the WiFi device (`parkeze-wifi-resolve`), and the sign-in proxy resolves the
same way. Not the gateway's resolver: it may ask over cellular and get the real
address, where a portal that hijacks DNS answers with its own. Not `nslookup`
against the WiFi's servers either: with the WiFi at metric 30 the route to them
is the SIM's, which is how USCGuest's OpenDNS was first asked over cellular.
And not a host route to those servers, which would move every lookup the
gateway makes onto a captive WiFi and send MQTT and reports to the portal. A change of
answer re-applies the tunnel and LoRa routing and sends a report, so
parkeze.net shows `wifiUplink` beside the gateway. `roam()` treats `portal` and
`offline` as down, except while somebody is signing in (see access.md).

### Cellular comes back on its own

`parkeze-cellular-watchdog` keeps the cellular link carrying traffic. It was
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
reaches parkeze.net, and the uplink buffer writes its queue to the card first.
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
tunnel to the parkeze.net hub, and gateway-link reaches it back down that
tunnel. No inbound port on the uplink is ever needed or opened.

## The management paths

```
                    ┌──────────────────┐
                    │   parkeze.net    │
                    └────────┬─────────┘
                             │
                 ┌───────────┴───────────┐
                 │                       │
        ┌────────▼────────┐    ┌─────────▼─────────┐
        │  gateway-link   │    │   gateway-link    │
        │  WireGuard hub  │    │  on the 1NCE VPN  │
        └────────┬────────┘    └─────────┬─────────┘
                 │  free                 │  metered
        ┌────────▼────────┐    ┌─────────▼─────────┐
        │  wg0            │    │   wwan0 (SIM)     │
        │  via eth0 ONLY  │    │                   │
        └─────────────────┘    └───────────────────┘
                        gateway
```

`net-api` chooses between them in `_management_host()`:

1. `mgmt_host`, if an operator pinned one.
2. The gateway's tunnel address, if the hub has had a handshake from it
   recently.
3. The SIM's address.

## The management tunnel

Plain kernel WireGuard, hub-and-spoke. There is no mesh and no coordination
server, and each gateway has one peer — the hub — at a single `/32`.

**Which hub.** An organization that has its own hub gets it: a
`wireguard-hub-<slug>` pod on the organization's own subnet and UDP port
(parkeze.net's `gateway-planes` chart, `wireguard_hubs` table). Every other
gateway is on Parkeze's hub in gateway-link's pod (`wg.net.parkeze.com:51820`,
`100.96.0.0/16`), which is also where every gateway enrolled before org hubs
existed stays until staff move it. parkeze.net picks the hub at enrolment
(`hub_for_org` in `net-api/utils/wireguard.py`); the gateway takes whatever
endpoint, hub key and hub address the answer gives, so nothing here differs
by organization. A gateway transferred to another organization is moved off
the old owner's hub the next time it enrols.

Chosen over Tailscale, which this replaced, because a 128MB MIPS gateway could
not carry it: `tailscaled` is a 26MB Go binary that left about 13MB of RAM free
at boot and stalled startup for minutes. WireGuard is in the kernel; the
package is about 60KB and there is no daemon.

**Enrollment.** The gateway generates its keypair on first start
(`/etc/parkeze/wireguard/`, private half 0600) and only the public half ever
leaves it. Once adopted, `parkeze-wireguard-enroll` posts that key to
`/api/v1/gateway-ops/wireguard/enroll`, proving which gateway it is with the
claim secret exactly as `/claim/poll` does, and gets back its tunnel address,
the hub's endpoint and the hub's public key. It retries in the background until
parkeze.net answers, so it works the same for a gateway adopted online, one
adopted from a signed offline bundle that later gets internet, and one whose
key has changed. The keypair survives firmware upgrades (`keep.d`).

**Why not netifd's `proto wireguard`.** It keeps the private key in
`/etc/config/network`, which is world-readable. `parkeze-wireguard` creates
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

`PARKEZE_WIREGUARD_ALLOW_CELLULAR` is `"0"` on every board today, and turning
it on is a real option, not a hard constraint — but off is the right default.

**Why.** Not primarily cost, though a tunnel left alone would keep itself
alive over whatever route it finds — a keepalive every 25 seconds, forever,
which is negligible against a SIM's allowance either way. The real reason is
that a cellular gateway is already reachable: gateway-link holds an OpenVPN
tunnel open into the SIM provider's CGNAT'd network, and every SIM answers on
a fixed address inside it (see "The management paths" above). WireGuard over
the same SIM to reach the same box would be a second management path doing the
first one's job.

**How.**

1. `wg0` carries WireGuard's native `fwmark` (`0x9700`), which marks the
   *encrypted outer* UDP it sends to the hub — the traffic that must be
   confined — rather than anything that travels inside `wg0`.

2. `parkeze-wireguard-route` puts a routing rule for that mark ahead of the
   main table, pointing at table 97, which contains the wired default route and
   nothing else.

3. A second rule at a lower priority makes marked packets **unreachable**. This
   is the part that matters: without it, a marked packet falls through to the
   main table when table 97 is empty and leaves over cellular — silently, and
   exactly in the situation the whole scheme exists to prevent.

The service refuses to bring the tunnel up if the rules did not install.

**What it means operationally.** When ethernet drops, the hub stops hearing
the gateway and its handshake goes stale. That is the designed behavior, not a
fault: parkeze.net sees it and manages the gateway over the SIM instead. A
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

`parkeze-backhaul-check` on the device follows the same rule: the wired path is
tested from the kernel's last WireGuard handshake (free), and the cellular path
only asks
whether a TCP connection to parkeze.net completes — no TLS, no certificate
chain. That is about 700 bytes, against roughly 6KB for an HTTPS GET to a health
endpoint. It is not the 200 of a bare handshake because nothing on the image can
stop there: BusyBox `nc` is the minimal build without `-z`, and there is no
ucode socket module, so curl connects in plain HTTP to the HTTPS port and the
answer is whether the connection was made. It only tests cellular at all when
the wired path is already known to be down.

The probe host comes from `PARKEZE_NET_URL`. It used to be a literal
`parkeze.net`, which no longer resolves, and the `nc -z` it ran never worked on
this image either — so until this was fixed the cellular path could not test as
up on any gateway.

### "Online" on the claim screen is a different question

Before adoption there is no tunnel, so "manageable" is false for every gateway
and says nothing about whether it can reach us. `parkeze-claim status` answers
the unadopted case from its own polling instead: each register and poll attempt
records whether parkeze.net answered, and `online` is true if one did within the
last two hours. No extra bytes — the claim loop was making those requests anyway.
Once adopted, `online` goes back to `parkeze-backhaul-check`.
