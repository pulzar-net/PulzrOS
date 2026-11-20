---
title: "Board features"
description: "A board says what it is for in one variable, and that one list decides what goes in its image, what its console shows and what its API answers."
---

A board says what it is for in one variable, and that one list decides what
goes in its image, what its console shows and what its API answers.

```sh
PULZR_FEATURES="lorawan cellular wifi gnss"
```

Before this, everything was in `PACKAGES_COMMON` and every page was in every
console. The Opal carried a concentrator stack, ChirpStack and an uplink broker
for a radio it does not have; its console would have offered LoRaWAN settings
that could only fail.

## The words

| Word | Packages | Console | API | Needs |
|---|---|---|---|---|
| `lorawan` | `PACKAGES_LORAWAN`: pulzr-concentrator, chirpstack-concentratord-sx1302, chirpstack-mqtt-forwarder, spi-tools, gpiod-tools, mosquitto-ssl | LoRaWAN | `/api/lorawan/` | |
| `gnss` | none (pulzr-gps is in pulzr-concentrator) | GNSS | `/api/gnss` | `PULZR_GPS` not `none` |
| `cellular` | `PACKAGES_CELLULAR`: pulzr-cellular, ModemManager, qmi-wwan; `PACKAGES_USB_CELLULAR` on a board with a USB host port | Backhaul > Cellular, Overview's Cellular card | `/api/network/cellular` | |
| `wifi` | `PACKAGES_WIFI`: pulzr-ap, wpad-openssl | Backhaul > WiFi, Access's setup AP | `/api/access/wifi`, `scan`, `ap`, `key` | |
| `lan` | `PACKAGES_LAN`: pulzr-lan | Network > LAN | `/api/lan/` | `PULZR_LAN_PORTS` |
| `dns` | `PACKAGES_DNS`: pulzr-dns | Network > DNS | `/api/dns/` | |
| `failover` | `PACKAGES_FAILOVER`: pulzr-uplinks | Network > Uplinks; Overview's Uplink row follows its order | `/api/uplinks/` | `cellular` or `wifi` |
| `speedtest` | `PACKAGES_SPEEDTEST`: pulzr-speedtest, librespeed-cli | Network > Speed Test ([speedtest.md](/PulzrOS/speedtest.html)) | `/api/speedtest/` | not `PULZR_FLASH_CONSTRAINED` |

Always present, on every board: Overview, Backhaul > Ethernet, Access, Panel,
Logs, System, the management tunnel, adoption, MQTT and the TUI.

`boards/common/board.conf` holds the list of words, each word's package group,
and two functions every caller shares:

- `pulzr_check_features` refuses an unknown word, a word whose "needs" the
  board does not meet (failover with nowhere to fail over to is one), and
  `PULZR_WAN_CELL_ENABLED=1` without `cellular`.
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
feature list existed; the list only named what they already carried. The Pis
have since gained `PACKAGES_USB_CELLULAR` (below). The Opal
loses pulzr-concentrator, chirpstack-concentratord-sx1302,
chirpstack-mqtt-forwarder, spi-tools, gpiod-tools, mosquitto-ssl and pulzr-ap. It keeps `cellular` because a USB modem is its
second uplink, and has no `wifi` because its radios have only Siflower's
vendor driver.

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
Only the RAK7289CV2 does, with pulzr-modbus (and the pulzr-edge binary it carries),
because its power board already talks Modbus. A built-in add-on upgrades with
the image and cannot be removed. No other board may carry either, the RAK7268CV2s in
production above all.

| Board | Built in |
|---|---|
| `rak7289cv2` | `pulzr-modbus` |
| every other | none |

## USB cellular is a board's, not a word

`PACKAGES_USB_CELLULAR` is the drivers for a modem somebody plugs in: MBIM,
AT ports, a Huawei stick, `usb-modeswitch`, and the USB Ethernet drivers and
`pulzr-usb-cellular` for a HiLink dongle or a tethered phone (see
[backhaul.md](/PulzrOS/backhaul.html), "Cellular adapters"). It is a group a board adds
to `PACKAGES_BOARD`, like the display and USB gadget groups, not a feature
word.

A word is what a board is for, and brings pages and endpoints with it. A USB
modem is the `cellular` feature's own page, endpoint and uplink, reached
through a different socket; what decides it is whether the board has a free
USB host port, which is hardware, the question the display and gadget groups
already answer per board. A word for it would have had no page to gate.

The Pis and the Opal take it. The RAK images do not: their modem is QMI and
soldered to their one USB port, and their flash is the tightest.
`pulzr_check_features` refuses `pulzr-usb-cellular` in `PACKAGES_BOARD`
without `cellular`, because it depends on pulzr-cellular and apk would
otherwise install the feature the board said it lacked.

## Packages that are not a feature's own

Some scripts are called from everywhere and live in pulzr-base, not in a
feature's package: `pulzr-backhaul-check` (adoption, the health gate, the
motd, the reset button, the console) moved there from pulzr-cellular so a
board without `cellular` still has it. `pulzr-gateway-facts` moved there
from pulzr-concentrator: `pulzr-claim report` sends its facts from every
gateway, and a board without `lorawan` that sent none was one Pulzar Cloud
could not tell ran PulzarOS. On such a board it reports
`concentrator=absent`. Everything else that reaches into a feature's package
already copes with it being absent: `pulzr-wifi-uplink` tests for
`pulzr-lora-route`, and the MQTT agent's ops fall back to `{}`.

`pulzr-boot-config` stays in pulzr-concentrator. It writes a Pi's
`config.txt`, every Pi has `lorawan`, and on a board without a Pi boot
partition the console's UART setting already reads it as absent.

## Adding a feature

1. Add the word to `PULZR_FEATURE_WORDS` and its line to the comment above
   it, and a `PACKAGES_<WORD>` group (empty is fine).
2. If it needs hardware, add the check to `pulzr_check_features`.
3. Add it to the `Feature` type in `console/src/types.ts`, put `feature` on its
   nav entries and wrap its routes in `Gated`.
4. Add its API prefix to `FEATURE_PREFIXES`.
5. List it on the boards that have it.

## What a router board may not do

The Opal is a Pulzar Cloud gateway like any other, and the devices on its LAN
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
  or our SIM. See [lan.md](/PulzrOS/lan.html). Still no DMZ, no site VPN that reaches
  the LAN, and no firewall rule editor.
- **Policy is per MAC**: `parkeze` or `internet`, through `pulzr-lan policy`,
  and a cellular rule beside it: allowed, blocked, or allowed but for some
  ports (`pulzr-lan cellular`). No blocklist, no allowlist, no per-client
  speed limit.
- **Local is reported.** A setting changed at the gateway (a reservation, an
  upstream DNS server, the uplink order) is in the gateway's report to Pulzar
  Net, as the LAN's state already is (`pulzr-lan status`).

## DNS and Uplinks

Both follow Network > LAN: a tool on the gateway that owns the state and
prints it as JSON (`pulzr-dns`, `pulzr-uplinks`), a console module that
calls it (`lib/dns.uc`, `lib/uplinks.uc`), audited actions, and a read-only
MQTT op (`dns`, `uplinks`) that answers with the tool's `status`, as `lan`
answers with `pulzr-lan status`.

**DNS** is dnsmasq's UCI. Upstream is the uplinks' own servers, or up to three
named ones that replace them (`noresolv`); a list where none resolves Pulzar's
MQTT host is refused, because the gateway resolves through the same dnsmasq.
Local names are `domain` sections the LAN resolves. A name under a Pulzar
domain is refused: a client whose policy is `parkeze` may reach the addresses
dnsmasq answered for Pulzar's names (`pulzr_dst`), so such a name would hand
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

### On Pulzar Cloud

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
the parts PulzarOS takes are `lan`, `dns` and `failover`. What is taken is the
layout, not the prose: one page per concern, cards with their own Apply, a
status badge on the uplink carrying traffic. Every GL card opens with a
paragraph explaining itself, which this console does not do.

| GL.iNet | PulzarOS |
|---|---|
| Internet: the Ethernet card (DHCP / static / PPPoE, VLAN, MTU) | Backhaul > Ethernet, one card per wired uplink, on every board |
| Port roles, VLANs, a second WAN | Network > Ports, on every board ([ports.md](/PulzrOS/ports.html)): each port an uplink, a LAN port or unused, tagged VLANs with roles of their own, applied and undone unless confirmed |
| Internet: Repeater | Backhaul > WiFi (`wifi`) |
| Internet: Cellular | Backhaul > Cellular (`cellular`) |
| Clients, LAN, DHCP, address reservation | Network > LAN (`lan`), built: `pulzr-lan status`, reserve, per-MAC policy and cellular rule, the open tunnel forwards read-only |
| Port forwarding | Network > LAN (`lan`), Exposed ports: wired and WiFi uplinks only, to reserved clients |
| Multi-WAN: priority, tracking, failover | Network > Uplinks (`failover`), built: the order, per-uplink tracking, the ping targets and thresholds; failover only, no load balance |
| DNS: hosts, upstream, rebind protection | Network > DNS (`dns`), built: automatic or custom upstream, local names, rebind protection and its allowed domains |
| DDNS | Network > DNS (`dns`), Dynamic DNS: the customer's own Cloudflare zone, not a vendor domain |
| Management Control | Access, already |
| Overview, Upgrade, Log, Time zone | System and Logs, already |

Left out, because each is a way into the LAN: DMZ, WireGuard and OpenVPN
servers and clients, LuCI's firewall rules. Port forwarding came in later as
exposed ports, and GL's DDNS as the customer's own (above). Left out
because nothing here needs them: guest network, network mode, drop-in
gateway, IGMP snooping, hardware acceleration, NAT mode, tethering, plug-ins,
NAS, GoodCloud and AstroWarp (Pulzar Cloud is the fleet manager).

The management tunnel is the organization's when the organization has a hub
of its own; see [backhaul.md](/PulzrOS/backhaul.html), "Which hub". An Opal enrols the
same way every gateway does and needs nothing different for it.
