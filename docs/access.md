# Setup access

How you reach a gateway that has dropped off the network — and why that is not
a way in for anyone else.

## The tension

A gateway on a pole that loses its uplink is otherwise a ladder and a laptop.
So it needs a local way back in. But every local way back in is also a local
way in *for a stranger*, and these devices sit in public car parks.

The two failure modes are not symmetric:

- Too locked down → a truck roll for every SIM outage. Expensive, annoying.
- Too open → someone in a car park takes a gateway, or the credentials on it.

So the design does not pick a point between them. It makes the recovery path
useless to anyone who is not already authorised.

## The rule

**An access point is only as open as the gateway has something to lose.**

| | Unadopted | Adopted |
|---|---|---|
| Holds credentials | no | yes: tailnet key, MQTT password, org identity |
| Setup AP | **open** | **WPA2, per-device key** |
| Portal can | claim the gateway | nothing, without a parkeze.net signature |
| Raised at boot | yes | no — only on fallback, or on request |

An unadopted gateway is a brick with a radio. There is nothing on it worth
stealing, and the only useful thing anybody can do through the portal is claim
it — which requires a Parkeze login and is audited. Giving that away costs
nothing and is what makes the out-of-box experience one tap.

An adopted gateway is different, and gets two independent factors:

1. **The AP passphrase.** Derived from a per-unit secret generated at first
   boot — *not* from the serial or MAC, which are printed on the case and
   broadcast in beacon frames. Deriving the key from those would mean anyone who
   can see the network can compute the way onto it.
2. **The offline recovery signature.** The portal still refuses to change
   anything without one. Same Ed25519 challenge-response as
   [`auth.md`](auth.md) — the gateway holds only a public key, so nothing
   extractable from its flash is a way in.

## The forced-fallback attack, and why it does not work

The obvious attack on a fallback like this: cut or jam the uplink until the
gateway gives up and raises its AP.

It works. It is also useless:

- the AP is WPA2 with a key the attacker does not have;
- the portal behind it wants a signature from parkeze.net;
- and every raise is journalled and reported the moment the gateway is back
  online — a gateway whose AP keeps appearing is telling you something, whether
  that is a flaky SIM or somebody in the car park with a jammer.

What the fallback *is* careful about is duration, because a permanently
broadcasting radio is a standing invitation to try:

- it waits `fallback_after` (default 15 min) of confirmed unreachability, so a
  blip does not raise a radio;
- it stays up for `window` (default 30 min), then drops;
- it comes down immediately if the backhaul returns;
- and the master switch in the console turns the whole mechanism off, for
  deployments that would rather have the truck roll.

## What the setup network can reach

Its own interface, its own firewall zone, and `forward REJECT` with no
zone-to-zone rule. A client on the setup AP can reach exactly one thing: this
gateway's console, on ports 80 and 443, plus DNS and DHCP.

Not the LAN. Not the WAN. Not the tailnet.

That matters most in the unadopted case, where the AP is open: an open AP that
also forwarded traffic would be a free, anonymous internet connection attached
to a customer's site — somebody else's incident to explain, and ours to have
caused.

## The captive portal

Two pieces and nothing more:

1. dnsmasq answers every name on `br-setup` with the gateway's own address, so
   whatever a phone probes to detect a portal resolves here.
2. A firewall redirect sends HTTP on the setup interface to the console.

The console then decides what to show based on adoption state. The portal is
not a separate application — it is the same React console, which is why there
is no second UI to keep in step.

## The ethernet port decides what it is

A Pi has one ethernet socket, so it is either the uplink or the console port —
it cannot be both. `parkeze-port-role` decides which, on every link-up.

| What is on the cable | Role | Behaviour |
|---|---|---|
| a site network | **wan** | takes a DHCP lease, carries the backhaul, accepts nothing inbound |
| a laptop | **lan** | hands out an address so the console is reachable with no setup |

### Why "no DHCP server" is not enough to conclude "laptop"

It is the obvious test, and it is wrong in a way that costs somebody else an
outage. A site network that uses static addressing — industrial kit, a controls
VLAN — has no DHCP server either. Concluding "laptop" there means answering
DHCP on a network we do not own, handing out addresses on the wrong subnet, and
publishing this gateway's console to it.

The two mistakes do not cost the same:

| Wrong guess | Cost |
|---|---|
| said **wan**, was a laptop | the laptop gets no address. Annoying — and the `.local` name below still works |
| said **lan**, was a network | rogue DHCP on a customer's LAN, plus our console exposed on it |

So **lan requires positive evidence** that the segment is unpopulated, and
anything ambiguous resolves to **wan**. Concretely:

1. No carrier → **lan**. Nothing to collide with, and the first laptop plugged
   in gets an address without waiting out a probe.
2. A DHCP server answers → **wan**. The one unambiguous signal.
3. No server, but the link is busy → **wan**, without serving anything. Most
   likely a statically addressed network.
4. No server and the link is quiet → **lan**.

Step 3 is the one that matters. It is deliberately only ever used to *refuse*
the lan role, never to grant it.

### Why a wrong guess is survivable

Both roles keep an IPv4 link-local address and answer mDNS, so the console is
reachable at

```
https://<hostname>.local
```

from a directly-connected laptop **whichever role was chosen**. A laptop with
no DHCP self-assigns `169.254.x.x` and can talk to us there.

That is what makes it safe to be conservative about serving DHCP: being wrong
costs a convenience, not access to the gateway. Without it, every conservative
choice would risk locking somebody out of a device in a car park, and the
pressure would be to guess "lan" — which is the expensive direction.

### Overriding it

`parkeze.port.role` is `auto`, `lan` or `wan`, settable from the console's
Access page and from parkeze.net. Pinning to `lan` is possible and the console
says plainly what it risks.

Multi-port boards do not use any of this: they have separate sockets and fixed
roles.

## Turning it all off

Both mechanisms are switchable from the console and from parkeze.net:

- `parkeze.ap.enabled=0` — never raise a radio, including on fallback.
- `parkeze.lan.dhcp_mode=never` — never serve DHCP.

A deployment that would rather send a van than have either is a legitimate
choice, and the console says plainly what turning them off costs.
