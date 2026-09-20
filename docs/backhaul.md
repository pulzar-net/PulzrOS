# Backhaul and management paths

A Parkeze gateway has two uplinks and two management paths, and the difference
between them is money.

## The uplinks

| | Ethernet | Cellular |
|---|---|---|
| Cost | free | billed per megabyte |
| Enabled by default | **yes** | **yes** |
| Operator-configurable in the console | **no** | yes (APN, on/off) |
| Route metric | 10 | 20 |

Both are defined in `feed/parkeze-base/files/etc/uci-defaults/20-parkeze-network`.

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
server: the hub is a sidecar in gateway-link's pod, and each gateway has one
peer — the hub — at a single `/32`.

Chosen over Tailscale, which this replaced, because a 128MB MIPS gateway could
not carry it: `tailscaled` is a 26MB Go binary that left about 13MB of RAM free
at boot and stalled startup for minutes. WireGuard is in the kernel; the
package is about 60KB and there is no daemon.

**Enrolment.** The gateway generates its keypair on first start
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
the gateway and its handshake goes stale. That is the designed behaviour, not a
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
