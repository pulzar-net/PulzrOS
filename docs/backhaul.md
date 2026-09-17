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

Ethernet is the wired backhaul. It comes up on DHCP, it is the path Tailscale
rides, and it is how a wired site is managed. It is on by default.

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
- **The tailnet follows on its own.** Bringing `wan` up fires the report and
  tailscale services' interface triggers. The report tells parkeze.net the
  gateway is wired, which is what permits it a tailnet — and a gateway that was
  cellular-only when adopted, and so was never issued a key, gets one in the
  report's response and joins.

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

Management works the other way round. The gateway *originates* an outbound
Tailscale connection, and gateway-link reaches it back down that tunnel. No
inbound port on the uplink is ever needed or opened.

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
        │  on the tailnet │    │  on the 1NCE VPN  │
        └────────┬────────┘    └─────────┬─────────┘
                 │  free                 │  metered
        ┌────────▼────────┐    ┌─────────▼─────────┐
        │  tailscale0     │    │   wwan0 (SIM)     │
        │  via eth0 ONLY  │    │                   │
        └─────────────────┘    └───────────────────┘
                        gateway
```

`net-api` chooses between them in `_management_host()`:

1. `mgmt_host`, if an operator pinned one.
2. The tailnet address, if the gateway has a node **and that node is online**.
3. The SIM's address.

## Tailscale never runs over cellular

This is a hard constraint, not a preference, and it is enforced three ways.

**Why.** Tailscale left alone will keep a tunnel alive over whatever route it
can find — DERP relays, keepalives every few seconds, a coordination-server
poll that never stops. On a SIM billed by the megabyte that is a bill, not a
backhaul. The SIM exists to be the cheap path of last resort; filling it with
tunnel chatter defeats the point of having it.

**How.**

1. `feed/parkeze-tailscale/files/etc/nftables.d/20-parkeze-tailscale.nft`
   marks every packet `tailscaled` originates, matched on the socket's owning
   uid. Installed as an fw4 include so it survives a firewall reload.

2. `parkeze-tailscale-route` puts a routing rule for that mark ahead of the
   main table, pointing at a table that contains the wired default route and
   nothing else.

3. A second rule at a lower priority makes marked packets **unreachable**. This
   is the part that matters: without it, a marked packet falls through to the
   main table when our table is empty and leaves over cellular — silently, and
   exactly in the situation the whole scheme exists to prevent.

The marking is on **uid, not on the `tailscale0` interface**. The traffic being
confined is the *encrypted outer* traffic to peers and DERP, which never
traverses `tailscale0`. A rule written against that interface confines the
wrong direction and looks correct right up until the bill arrives.

**What it means operationally.** When ethernet drops, the tailnet node goes
offline. That is the designed behaviour, not a fault. parkeze.net sees the node
go offline and manages the gateway over the SIM instead.

### A cellular-only gateway does not start tailscaled at all

The three mechanisms above *confine* tailnet traffic to the wired path. They do
not stop tailscaled running on a gateway that has no wired path — it came up,
joined nothing, and sat there. Confined, but pointless.

`parkeze-claim report` closes that. The gateway sends what it can see — is
there a modem, is the wired path usable — parkeze.net derives the backhaul from
those facts, and hands back whether this gateway may run a tailnet. The answer
lands in `parkeze.backhaul.tailscale`, which `/etc/init.d/parkeze-tailscale`
checks alongside `PARKEZE_TAILSCALE_ENABLED`.

Two properties worth stating:

**The device does not decide.** It reports readings, never a conclusion. A
gateway that could name its own backhaul could name the one that gets it a
tailnet key, and the whole point of the rule is that a metered SIM never
carries a tunnel. The derivation lives in net-api, in one function.

**Absent means start.** Only an explicit `0` suppresses tailscaled. A gateway
that has never reported — or cannot reach parkeze.net at all — must still come
up manageable, and the confinement above is what makes being wrong in that
direction harmless.

**Ethernet is sticky.** `wiredUsable` is a live reading, so a wired site whose
switch is rebooting reports false for a minute. Letting that flip the backhaul
would mean every wired-with-SIM-backup site flapping with its uplink — and the
SIM is the backup precisely because the site is wired. Once wired, only a
person moves a gateway off wired.

## Who may reach a gateway on the tailnet

The gateway runs a real kernel TUN and does **not** set `--shields-up`, because
it has to accept the one inbound connection the whole design rests on:
gateway-link reaching it back down the tunnel.

> Both of those were set the other way at first — `--tun=userspace-networking`
> and `--shields-up`. Each blocks inbound on its own. The gateway joined the
> tailnet, appeared online, and was unreachable on it, which looks exactly like
> the tunnel being down.

So access is restricted **server-side, by the tailnet ACL**, keyed on the tag
every gateway advertises. Enforced by the coordination server rather than by a
flag on a device we may not be able to reach, and changeable without touching
the fleet:

```jsonc
{
  "tagOwners": { "tag:gateway": ["autogroup:admin"] },
  "acls": [
    // gateway-link is the only thing that may open a connection to a gateway.
    { "action": "accept", "src": ["tag:gateway-link"], "dst": ["tag:gateway:22,80,443"] },

    // Gateways originate nothing on the tailnet. They are endpoints: they
    // accept management and talk to nobody, so a compromised one is not a way
    // to reach anything else.
    { "action": "accept", "src": ["tag:gateway"], "dst": [] }
  ]
}
```

The gateway also never passes `--advertise-routes` or `--advertise-exit-node`,
so it offers no path to the site network behind it. A customer's parking
hardware is not ours to expose, and that property comes from not advertising it
rather than from a mode that also breaks management.

## Seeing which path works, for free

`GET /api/v1/gateway-ops/<eui>/backhaul` answers entirely from cloud APIs — the
Tailscale coordination server and 1NCE. Neither costs the gateway a byte, so
the console can poll it and a wall display can sit on it all day.

The obvious implementation of "is my gateway reachable" is to ping it. On this
fleet the obvious implementation is the expensive one. If you extend that
endpoint, extend it from an API that already knows.

`parkeze-backhaul-check` on the device follows the same rule: the wired path is
tested through tailscaled's own view (free), and the cellular path only asks
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
