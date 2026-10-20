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

The local way in is **the ethernet port**, not WiFi. It costs nothing to leave
available — a cable is physical access, which is a boundary we were never
defending anyway — and it works in a car park basement where a radio does not.
The setup AP still exists for the case the port cannot be reached, and it is
off until somebody turns it on.

So the design does not pick a point between them. It makes the recovery path
useless to anyone who is not already authorized.

## The rule

**An access point is only as open as the gateway has something to lose.**

| | Unadopted | Adopted |
|---|---|---|
| Holds credentials | no | yes: tunnel key, MQTT password, org identity |
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

Not the LAN. Not the WAN. Not the management tunnel.

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

## Signing the gateway in to a WiFi portal

The other direction: a WiFi network the gateway joined wants somebody to click
through its sign-in page (`parkeze-wifi-uplink` says `portal`, backhaul.md).
That somebody has to be the gateway, since a portal admits the device that
loaded it, by MAC and address. So the console's **Sign in** on the WiFi page
opens the network's page *as the gateway*: a proxy on the gateway fetches it out
of the WiFi radio and hands it to the browser — whether that browser is on the
cable, on the setup AP, or on parkeze.net with the gateway on cellular.

- **Its own origin.** A portal's page is somebody else's HTML and script, and on
  the console's origin it could use the console session. The proxy is a second
  uhttpd on **8443** (`signin.uc`), opened wherever the console is, and the
  console's own listener has no `/signin`. Through parkeze.net it is a second
  device host for the same gateway: the console asks its own host for
  `/__signin`, and net-api opens one that reaches 8443 (net-db 098).
- **Getting in.** The console, signed in, mints a one-use ticket good for a
  minute; the proxy trades it for a cookie on its own origin, good for half an
  hour.
- **When it answers.** While the network is `portal` or `offline`, and for ten
  minutes after it opens. Not otherwise: on an open network it would be a way
  into whatever is behind the customer's WiFi.
- **Names.** A portal's hostnames are resolved by the WiFi network's own DNS
  servers, out of the WiFi device (`parkeze-wifi-resolve`), so a portal that
  answers every name with its own address is followed to its page.
- **What it passes on.** Never the browser's cookies (on a local address those
  include the console's session) or its Authorization. The portal's cookies
  stay in one jar on the gateway. A certificate the gateway does not trust
  gets a page that says so and a link to continue, as a browser asks.
- **What it cannot follow.** Links in HTML and CSS, redirects, and fetch/XHR
  are rewritten. A script that builds an absolute URL and assigns it to
  `location` is not; such a portal does not load through it.

The better answer at a site that has one is the network's own device
registration: the WiFi page shows the station's MAC for exactly that.

## The ethernet port

A Pi has one ethernet socket. It is the uplink **and** the console port, at the
same time, permanently. It holds three addresses:

| | Address | What it is for |
|---|---|---|
| `wan` | DHCP lease | the backhaul, up the moment the cable reaches a network |
| `console` | `192.168.61.1` | fixed, printed on the label, never moves |
| `linklocal` | `169.254.61.1/16` | a laptop plugged straight in, with nothing configured |

Nothing is detected and nothing is chosen.

### The version that did choose, and why it is gone

The first design had the port pick a role on every link-up: a site network made
it a WAN, a bare laptop made it a LAN that served DHCP. The detection was
careful — it treated "no DHCP server" as insufficient evidence of a laptop,
because a statically addressed controls network looks identical, and resolved
anything ambiguous to WAN.

It was still the wrong shape. Two reasons:

**The detection cannot be made right.** Not "was not yet"; cannot. The
distinguishing evidence does not exist on the wire. Every version of that code
is a heuristic with a failure mode that costs somebody else an outage, and the
careful version mostly bought safety by refusing to serve DHCP — which is to
say, by doing what we now do unconditionally.

**Serving DHCP was never worth the risk it carried.** The only thing the LAN
role added over holding a static address was handing an address to a directly
connected laptop. Every laptop already self-assigns a link-local address when
nothing answers DHCP, which reaches the gateway anyway. We were taking on the
risk of rogue DHCP on a customer network to save a step that happens by itself.

Remove the role and both problems go at once. Nothing to detect, nothing to
configure, nothing to get wrong, and one less service listening.

### So this gateway never serves DHCP

Not in any mode, not with a config flag, not on a bench. A second DHCP server
on a network we do not own hands out addresses on the wrong subnet, breaks
whatever was working, and is very hard for the site to trace back to a LoRaWAN
gateway on a pole.

The installer-facing consequence — a laptop that says "no internet" and
self-assigns `169.254.x.x` — is stated on the Access page rather than left to
be discovered.

### Reaching it

Plug a laptop into the port and open:

```
https://parkeze-<serial>.local
```

That works with no configuration on either end: the laptop self-assigns a
link-local address, and `umdns` answers the name on the link-local interface.
`https://parkeze.local` works the same way and does not need the serial off
the label: on the end of a cable there is only ever one gateway for it to
mean. `https://192.168.61.1` is the fallback for when mDNS is blocked.

mDNS is deliberately *not* answered on the uplink side. The same socket faces
whatever site network the gateway is patched into, and advertising there would
put our hardware in the service browser of every machine on it.

### What the site network can reach

Nothing. The port sits in the `wan` zone at `input DROP`, with two carve-outs
matched on **source address**, not interface:

| Source | Ports |
|---|---|
| `169.254.0.0/16` | tcp 22, 80, 443 + udp 5353 |
| `192.168.61.0/24` | tcp 22, 80, 443 |

A host only holds a `169.254` address when it is on a segment with no DHCP
server — on this port, that means it is plugged into the gateway and nothing
else. `192.168.61.0/24` is our own subnet, which a laptop only reaches us from
deliberately.

Two zones over one device would have been the obvious way to express this, and
it does not work: fw4 would match both on `iifname eth0` and the result would
depend on rule order. Source addresses are unambiguous.

This is not the security boundary — authentication is, and anyone holding the
cable is inside any perimeter we could draw. The carve-out only stops a routed
network from reaching the login page at all.

## The USB port

On a Pi 4 or Pi 5 the USB-C socket is also a way in. Plugged into a laptop,
the gateway shows up as two things at once:

- **A network interface.** The laptop gets an address by DHCP and the console
  is at `https://parkeze.local`, or `https://192.168.63.1` without mDNS.
  Windows 11, macOS, Linux and ChromeOS need no driver (CDC-NCM).
- **A serial port**, with the terminal UI on it behind the console's sign-in —
  see [`tui.md`](tui.md). Every OS binds it without a driver too.

### Why this port serves DHCP

The ethernet port never does, because nothing can tell a laptop from a
customer's network and guessing wrong is somebody else's outage. That question
does not exist here: the only thing on the other end of a USB cable is the one
computer it is plugged into. So the port hands that computer an address — and
nothing else. No default route and no DNS server, so a laptop that is also on
WiFi keeps its own internet and its own resolver.

### What it can reach

Its own firewall zone, `forward DROP`, and only tcp 22, 80 and 443 plus DHCP and
mDNS in. The USB port is a way to this gateway's console and not a route onto
the site, the uplink or the management tunnel.

### Power

The USB-C socket on a Pi 4 and Pi 5 is the power input as well as the device
port. A laptop plugged into it is also the power supply, and a laptop port
gives a fraction of what a Pi with a concentrator and a modem draws: expect
brownouts. A gateway on PoE or powered through its header is fine. One powered
from its USB-C socket needs a splitter that takes data from the laptop and
power from the supply.

### Which boards

The Pi 4 and Pi 5 only. A Pi 3's USB sockets all hang off its LAN hub, so the
SoC can only ever be a host. The RAK units' USB-C socket is a USB-to-serial
bridge on the console UART — the terminal UI is there already, at 57600 — and
their SoC has no USB device controller at all.

## The screen

A Pi with a screen attached at boot shows the terminal UI on it, behind the
console's sign-in, in place of OpenWrt's passwordless login on tty1. With no
screen attached, nothing runs: the firmware leaves HDMI unpowered, there is no
framebuffer, and nothing draws. A screen plugged into a gateway that is already
running stays dark until the next boot — see `parkeze-display-attached` for why
that trade was made.

## Most installs never touch any of this

The normal path involves no local connection to the gateway. Plugged into
anything with a route out, it takes DHCP, registers its claim with parkeze.net
and appears in the pending list. The installer matches the EUI on the label and
adopts it from the parkeze.net console, on their phone, without opening a
laptop.

Everything above is the fallback for when that does not happen — which is
exactly why it has to work with zero configuration rather than merely work.

## Turning it all off

Both mechanisms are switchable from the console and from parkeze.net:

- `parkeze.ap.enabled=0` — never raise a radio, including on fallback. **This
  is the default.** The AP is opt-in: field setup does not use WiFi, and a
  radio standing on a customer site is something we are responsible for.

There is no switch for DHCP, because it is never served, and none for the
ethernet port's console addresses, because switching them off would remove the
last way to reach a gateway that has lost its backhaul.
