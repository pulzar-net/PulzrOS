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

## LAN DHCP

Separate mechanism, different risk, same page in the console.

The LAN port serves two situations that want opposite behaviour:

- **a laptop plugged straight in** needs an address, or the installer is
  configuring a static one by hand in a car park;
- **the port patched into a site network** must not get one. A second DHCP
  server on somebody's LAN hands out addresses on the wrong subnet and points
  clients at a gateway that routes nowhere. It is an outage, on equipment that
  is not ours, and genuinely hard for the site to trace back to a LoRaWAN
  gateway nobody was thinking about.

`parkeze-lan-guard` decides by asking: it acts as a DHCP client for a moment
(`udhcpc -n -q -s /bin/true`, so no lease is ever applied) and sees whether
anything answers. Three tries over about nine seconds, because a single
discover gets dropped often enough on a live corporate LAN that one-shot
probing would decide "empty segment" on a busy network.

It **fails closed**: no carrier is treated as "safe to serve", anything
ambiguous as "do not". `dhcp.lan.ignore` starts at `1` at first boot so a
gateway does not serve DHCP for the nine seconds before the first probe
finishes — which it would do onto whatever it is plugged into.

Re-probed on every `ifup`, so a gateway configured on a bench and then patched
into the site stops serving before anyone notices it started.

The static console address stays either way. `192.168.61.1` is on the label,
the MOTD and the docs, so it answers whether or not the port is also on
somebody's network.

## Turning it all off

Both mechanisms are switchable from the console and from parkeze.net:

- `parkeze.ap.enabled=0` — never raise a radio, including on fallback.
- `parkeze.lan.dhcp_mode=never` — never serve DHCP.

A deployment that would rather send a van than have either is a legitimate
choice, and the console says plainly what turning them off costs.
