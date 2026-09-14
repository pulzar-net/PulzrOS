# Backhaul and management paths

A Parkeze gateway has two uplinks and two management paths, and the difference
between them is money.

## The uplinks

| | Ethernet | Cellular |
|---|---|---|
| Cost | free | billed per megabyte |
| Configured | yes | yes |
| Enabled by default | **no** | **yes** |
| Operator-configurable in the console | **no** | yes (APN, on/off) |
| Route metric | 10 | 20 |

Both are defined in `feed/parkeze-base/files/etc/uci-defaults/20-parkeze-network`.

### Why ethernet is present but disabled and hidden

Every gateway we deploy is either cellular-backhauled or is a wired unit that
parkeze.net configures during adoption. Neither wants a site technician
enabling a DHCP client on the WAN port and putting the gateway on a network
nobody has assessed.

So the interface is fully defined and simply not brought up, and the console
renders it read-only with the reason attached. Two ways to turn it on:

- `PARKEZE_WAN_ETH_ENABLED=1` in a board's `board.conf`, at build time.
- One UCI set from the management plane, at any time.

It is *defined* rather than absent because a disabled interface can be enabled
with one `uci set`, while a missing one needs a whole interface definition
pushed to a device we may only reach over a metered SIM.

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

## Seeing which path works, for free

`GET /api/v1/gateway-ops/<eui>/backhaul` answers entirely from cloud APIs — the
Tailscale coordination server and 1NCE. Neither costs the gateway a byte, so
the console can poll it and a wall display can sit on it all day.

The obvious implementation of "is my gateway reachable" is to ping it. On this
fleet the obvious implementation is the expensive one. If you extend that
endpoint, extend it from an API that already knows.

`parkeze-backhaul-check` on the device follows the same rule: the wired path is
tested through tailscaled's own view (free), and the cellular path gets a bare
TCP handshake and no more — about 200 bytes, against roughly 6KB for an HTTPS
GET to a health endpoint once the certificate chain is counted. It only tests
cellular at all when the wired path is already known to be down.
