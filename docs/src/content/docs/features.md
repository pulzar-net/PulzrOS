---
title: "Board features"
description: "A board says what it is for in one variable, and that one list decides what goes in its image, what its console shows and what its API answers."
---

A board says what it is for in one variable, and that one list decides what
goes in its image, what its console shows and what its API answers.

```sh
PULZR_FEATURES="wifi gnss"
```

Before this, everything was in `PACKAGES_COMMON` and every page was in every
console. The Opal carried a concentrator stack, ChirpStack and an uplink broker
for a radio it does not have; its console would have offered LoRaWAN settings
that could only fail.

LoRaWAN and cellular are not words: they are add-ons (below), built into the
image of a board that has the radio as part of it and offered where one is
plugged in.

## The words

| Word | Packages | Console | API | Needs |
|---|---|---|---|---|
| `gnss` | none (pulzr-gps is in pulzr-lorawan, on while it is installed) | GNSS | `/api/gnss` | `PULZR_GPS` not `none`; pulzr-lorawan built in or offered |
| `wifi` | `PACKAGES_WIFI`: pulzr-ap, wpad-openssl | Backhaul > WiFi, Access's setup AP | `/api/access/wifi`, `scan`, `ap`, `key` | |
| `lan` | `PACKAGES_LAN`: pulzr-lan | Network > LAN | `/api/lan/` | `PULZR_LAN_PORTS` |
| `dns` | `PACKAGES_DNS`: pulzr-dns | Network > DNS | `/api/dns/` | |
| `failover` | `PACKAGES_FAILOVER`: pulzr-uplinks | Backhaul's order and Tracking; Overview's Uplink row follows its order | `/api/uplinks/` | cellular (built in or the add-on) or `wifi` |
| `speedtest` | `PACKAGES_SPEEDTEST`: pulzr-speedtest, librespeed-cli | Network > Speed Test ([speedtest.md](/PulzrOS/speedtest.html)) | `/api/speedtest/` | not `PULZR_FLASH_CONSTRAINED` |

`lorawan` and `cellular` are not board words: they are the words of the
pulzr-lorawan and pulzr-cellular add-ons (below). `gnss` is the board's
receiver, which ChirpStack Concentratord holds for GPS time and PPS, so
`system.features()` reports it only while `lorawan` is on.

Always present, on every board: Overview, Backhaul > Ethernet, Access, Panel,
Logs, System, the management tunnel, adoption, MQTT and the TUI.

`boards/common/board.conf` holds the list of words, each word's package group,
and two functions every caller shares:

- `pulzr_check_features` refuses an unknown word, a word whose "needs" the
  board does not meet (failover with nowhere to fail over to is one), and
  `PULZR_WAN_CELL_ENABLED=1` on a board that can have no cellular, built in
  or as the add-on.
  `build.sh` and `scripts/check-deps.sh` both run it.
- `pulzr_packages` prints `PACKAGES_COMMON`, then each listed word's group,
  then `PACKAGES_BOARD`, then `PULZR_ADDONS_BUILTIN`. `build.sh` and `scripts/check-deps.sh` both install
  from it, so the dependency check sees exactly what the image gets.

On the gateway, `PULZR_FEATURES` is in `/etc/pulzr/board.conf` with every
other `PULZR_` value. The console reads it from `GET /api/system/features`
(`system.features()` in `lib/system.uc`). Nav entries in `console/src/nav.ts`
carry a `feature`; the sidebar leaves out what the board lacks, `App.tsx` sends
the route home, and the API answers its endpoints `404 Not on this board.`
(`FEATURE_PREFIXES` in `api/index.uc`), because the scripts behind them are not
in the image and a missing binary otherwise surfaces as a 500.

## The boards

Each board's words are on its [Hardware](/PulzrOS/hardware.html) page, read from its
`board.conf`.

The Pi and RAK images were package-for-package what they were before the
feature list existed; the list only named what they already carried. The
Opal carries no LoRaWAN and no cellular. Since cellular became an add-on, the
Opal, the Pis and the RAK7391 carry none of it until a modem is plugged in
and the add-on installed; since LoRaWAN did, the Pis carry none of it until a
concentrator is found and the add-on installed.

RAK gateways never get the router set: their one port is the uplink and the
console at once (see [access.md](/PulzrOS/access.html)), and there is nothing to route
for.

## Add-ons bring words too

An add-on (see [addons.md](/PulzrOS/addons.html)) is installed on a running gateway, not
built into its image, and may carry a feature word of its own in its `addon`
file: `ADDON_FEATURE="modbus"` for pulzr-modbus, `"bluetooth"` for pulzr-ble. `system.features()` returns
`PULZR_FEATURES` plus the word of each add-on whose
`/usr/libexec/pulzr/addon-health/<name>` is on the gateway, which apk removes
with the package. So a Modbus page gated on `modbus` shows where pulzr-modbus is
installed and nowhere else. An add-on's word must not be a board word
(`scripts/check-addons.sh`): the two would gate one page on different things.

A board can carry an add-on in its image with `PULZR_ADDONS_BUILTIN`, which
`pulzr_packages` appends and `pulzr_check_features` checks names an add-on.
A built-in add-on upgrades with the image and cannot be removed, and its word
is on from the first boot, because its addon-health script is in the image.
The boards sold as LoRaWAN gateways carry pulzr-lorawan, and
`scripts/check-addons.sh` refuses a board that declares its concentrator
slots without it. The boards with a soldered LTE modem carry pulzr-cellular. Only the
RAK7289CV2 carries pulzr-modbus (and the pulzr-edge binary it brings),
because its power board already talks Modbus; no other board may, the
RAK7268CV2s in production above all.

| Board | Built in |
|---|---|
| `rak7266`, `rak7267`, `rak7268v2`, `rak7289v2`, `rak7391`, `dragino-lps8n`, `sensecap-m2` | `pulzr-lorawan` |
| `rak7268c`, `rak7268cv2` | `pulzr-lorawan`, `pulzr-cellular` |
| `rak7289cv2` | `pulzr-lorawan`, `pulzr-modbus`, `pulzr-cellular` |
| every other | none |

## LoRaWAN is an add-on

LoRaWAN was the `lorawan` word, and so a fact about the image: a Pi built
without a HAT carried ChirpStack and an uplink broker for nothing, and a Pi
built with one could not be told apart by anything but its concentrator
status. It is the add-on pulzr-lorawan, with the `lorawan` word:

- **Built in** where the concentrator is part of the product: every RAK
  gateway, the Dragino LPS8N and the SenseCAP M2. A sysupgrade replaces the
  image whole, so it is in the new one too, and the gateway never comes up
  without it.
- **Offered** on a kit, the Pis, when pulzr-probe finds a concentrator on SPI
  or USB, the way a Zigbee stick is.
- **Kept by its configuration** on a Pi, across any upgrade: its
  `ADDON_CONFIG` is `pulzr.concentrator.present`, the slots that answered,
  which `/etc/config/pulzr` keeps as it keeps the WiFi the gateway joins. A
  gateway whose configuration says a concentrator answered and that has no
  package (one upgraded from an image that carried LoRaWAN) downloads it once
  the firmware is confirmed, retrying with backoff and showing it pending
  meanwhile, and finds its region and slots where they were.

Not the Opal: its target is source-only, and no OpenWrt SDK builds ChirpStack
for its architecture.

## Cellular is an add-on

Cellular was a word until the Opal, with 115 MB of RAM and an upgrade that
needed every MB of it, was found running ModemManager and usbmuxd with no
modem plugged in. Most of the boards that took it have no modem of their own:
whatever cellular there is, is plugged into a USB host port, often never. So
it is the add-on pulzr-cellular (see [addons.md](/PulzrOS/addons.html)), with the `cellular`
word:

- **Built in** where the modem is soldered on: the RAK7268C, RAK7268CV2 and
  RAK7289CV2 (`PULZR_ADDONS_BUILTIN`), with ModemManager and the QMI driver
  alone, as their images always had.
- **Offered** where it is plugged in: the Opal, the Pis and the RAK7391,
  whose LTE is an optional mPCIe card on USB (its `ADDON_BOARDS`). Their
  images carry no modem driver. `pulzr-radios` reports a modem plugged into
  one (`modems`, see [usb-radios.md](/PulzrOS/usb-radios.html)), and Pulzr Net offers the
  add-on: ModemManager with glib, libqmi and libmbim, `usb-modeswitch`,
  `usbmuxd` and the kmods for MBIM, QMI, AT ports, a Huawei stick and the
  USB Ethernet modems. In v0.4.0-rc.9 that is about 3.7 MB to download and
  11 MB installed on the Opal, and 4.8 MB and 16 MB on a Pi, beyond what
  the image already has (libopenssl3, libcurl4, usbids); libqmi,
  ModemManager and glib are most of it.
- **Neither** on the boards with no modem and no USB port for one, which
  set `PULZR_WAN_CELL_ENABLED=0`.

What it brings per architecture is in `feed/pulzr-cellular/arches`. A board
that takes it as an add-on gets its kmods from the add-on repository, built
for exactly the kernel of the release (`build-addons.sh`).

## Packages that are not a feature's own

Some scripts are called from everywhere and live in pulzr-base, not in a
feature's package: `pulzr-backhaul-check` (adoption, the health gate, the
motd, the reset button, the console) moved there from pulzr-cellular so a
board without cellular still has it. `pulzr-gateway-facts` moved there
from the LoRaWAN package: `pulzr-claim report` sends its facts from every
gateway, and a board without LoRaWAN that sent none was one Pulzr Cloud
could not tell ran PulzrOS. On such a board it reports
`concentrator=absent`. Everything else that reaches into a feature's package
already copes with it being absent: `pulzr-wifi-uplink` tests for
`pulzr-lora-route`, and the MQTT agent's ops fall back to `{}`.

`pulzr-boot-config` is in pulzr-base. It writes a Pi's `config.txt`: SPI on,
for a concentrator HAT to be found before LoRaWAN is installed, and the
wiring the Bluetooth add-on, the display and the USB device port need. On a
board without a Pi boot partition it does nothing.

## Adding a feature

1. Add the word to `PULZR_FEATURE_WORDS` and its line to the comment above
   it, and a `PACKAGES_<WORD>` group (empty is fine).
2. If it needs hardware, add the check to `pulzr_check_features`.
3. Add it to the `Feature` type in `console/src/types.ts`, put `feature` on its
   nav entries and wrap its routes in `Gated`.
4. Add its API prefix to `FEATURE_PREFIXES`.
5. List it on the boards that have it.

## What a router board may not do

The Opal is a Pulzr Cloud gateway like any other, and the devices on its LAN
are listed under it.
Three rules follow, and every router page keeps them:

- **Two ways in, kept apart.** The tunnel forward the cloud asks for
  (`lan-forward`) is ours: from `wg0`, bounded in time. An exposed port
  (`pulzr-lan expose`) is the site's: from a wired or WiFi uplink's own
  address to one reserved client, opened at the gateway, for a customer who
  serves something to the internet through their own router and their own
  DNS name. Neither reaches the other's path: an exposed port never answers
  on `wg0` or a cellular device, and a connection through one is dropped
  rather than leave on cellular. Customer traffic does not ride our tunnel
  or our SIM. A tunnel (`pulzr-lan tunnel`) is the customer's too: WireGuard
  the gateway dials out to their own server, which reaches only the devices
  it was given, at their own addresses, never over cellular. See
  [lan.md](/PulzrOS/lan.html). Still no DMZ and no firewall rule editor.
- **Policy is per MAC**: `internet` (the default, metered per device) or
  `parkeze` (Pulzr, NTP and DNS only), through `pulzr-lan policy`,
  and a cellular rule beside it: allowed, blocked, or allowed but for some
  ports (`pulzr-lan cellular`). No blocklist, no allowlist, no per-client
  speed limit.
- **Local is reported.** A setting changed at the gateway (a reservation, an
  upstream DNS server, the uplink order) is in the gateway's report to Pulzr
  Net, as the LAN's state already is (`pulzr-lan status`).

## DNS and Uplinks

Both follow Network > LAN: a tool on the gateway that owns the state and
prints it as JSON (`pulzr-dns`, `pulzr-uplinks`), a console module that
calls it (`lib/dns.uc`, `lib/uplinks.uc`), audited actions, and a read-only
MQTT op (`dns`, `uplinks`) that answers with the tool's `status`, as `lan`
answers with `pulzr-lan status`.

**DNS** is dnsmasq's UCI. Upstream is the uplinks' own servers, or up to three
named ones that replace them (`noresolv`); a list where none resolves Pulzr's
MQTT host is refused, because the gateway resolves through the same dnsmasq.
Local names are `domain` sections the LAN resolves. A name under a Pulzr
domain is refused: a client whose policy is `parkeze` may reach the addresses
dnsmasq answered for Pulzr's names (`pulzr_dst`), so such a name would hand
that client any address. So is a reservation's name, which pulzr-lan already
serves. Rebind protection stays on unless somebody turns it off, with the
domains allowed past it listed.

**Dynamic DNS** is the customer's name in the customer's Cloudflare zone,
kept on the site's public address by ddns-scripts (service `pulzr` in UCI
`ddns`), for exposed ports. Pulzr hosts no name and holds no account. The
address is asked of Cloudflare's own echo (`ip_source web`, because behind a
site router the uplink's address is private), and the question and the
update both leave on the wired or WiFi uplink chosen (`bind_network`), never
cellular. The API token goes in on stdin (`pulzr-dns ddns-token`), lives in
`/etc/config/ddns` at mode 600, and `status` says only whether one is set.

**Uplinks** sets each uplink's route metric from the order: 10, 20, 30, 40.
Tracking pings out of each tracked uplink's own device and, after `down`
misses, moves it behind the others (100 plus its step); `up` answers bring it
back. Ethernet is tracked by default, cellular only when turned on, and the
WiFi's health is pulzr-wifi-uplink's portal check. The tunnel's wired path
asks `pulzr-uplinks usable wan`, so it leaves a dead cable too. See
[backhaul.md](/PulzrOS/backhaul.html), "Failover".

Neither opens anything: a name and a metric reach nothing that was not
reachable before. Dynamic DNS names an address; the exposed ports behind it
are the LAN page's.

### On Pulzr Cloud

the cloud asks a gateway with a LAN for `uplinks` and `dns` on each lan-paths
run, and again when somebody opens its Backhaul, and keeps the last answer
under the gateway's metadata (`utils/gateway_router.py`, allowlisted as the
power board's record is). The gateway's Backhaul shows the order with each
uplink's state, the tracking settings, the upstream servers, local names and
rebind protection, read-only: a change is made at the gateway, which checks
it against its own state. The claim report's `wiredUsable` and `tunnelVia`
follow tracking on their own.

## The router set, from GL.iNet's

The Opal ships with GL.iNet's admin panel (firmware 4.8.3). Its feature
inventory, read off a stock unit, is in the router-features session's notes;
the parts PulzrOS takes are `lan`, `dns` and `failover`. What is taken is the
layout, not the prose: one page per concern, cards with their own Apply, a
status badge on the uplink carrying traffic. Every GL card opens with a
paragraph explaining itself, which this console does not do.

| GL.iNet | PulzrOS |
|---|---|
| Internet: the Ethernet card (DHCP / static / PPPoE, VLAN, MTU) | Backhaul > Ethernet, one card per wired uplink, on every board |
| Port roles, VLANs, a second WAN | Network > Ports, on every board ([ports.md](/PulzrOS/ports.html)): each port an uplink, a LAN port or unused, tagged VLANs with roles of their own, applied and undone unless confirmed |
| Internet: Repeater | Backhaul > WiFi (`wifi`) |
| Internet: Cellular | Backhaul > Cellular (`cellular`) |
| Clients, LAN, DHCP, address reservation | Network > LAN (`lan`), built: `pulzr-lan status`, reserve, per-MAC policy and cellular rule, the open tunnel forwards read-only |
| Port forwarding | Network > LAN (`lan`), Exposed ports: wired and WiFi uplinks only, to reserved clients |
| Site VPN | Network > LAN (`lan`), Tunnels: WireGuard out to a customer's server, what it reaches on the LAN, internet through it off by default |
| Multi-WAN: priority, tracking, failover | Backhaul (`failover`), built: the order by drag and drop, per-uplink tracking, the ping targets and thresholds; failover only, no load balance |
| DNS: hosts, upstream, rebind protection | Network > DNS (`dns`), built: automatic or custom upstream, local names, rebind protection and its allowed domains |
| DDNS | Network > DNS (`dns`), Dynamic DNS: the customer's own Cloudflare zone, not a vendor domain |
| Management Control | Access, already |
| Overview, Upgrade, Log, Time zone | System and Logs, already |

Left out, because each is a way into the LAN: DMZ, WireGuard and OpenVPN
servers and clients, LuCI's firewall rules. Port forwarding came in later as
exposed ports, and GL's DDNS as the customer's own (above). Left out
because nothing here needs them: guest network, network mode, drop-in
gateway, IGMP snooping, hardware acceleration, NAT mode, tethering, plug-ins,
NAS, GoodCloud and AstroWarp (Pulzr Cloud is the fleet manager).

The management tunnel is the organization's when the organization has a hub
of its own; see [backhaul.md](/PulzrOS/backhaul.html), "Which hub". An Opal enrols the
same way every gateway does and needs nothing different for it.
