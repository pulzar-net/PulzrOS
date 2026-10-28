# Board features

A board says what it is for in one variable, and that one list decides what
goes in its image, what its console shows and what its API answers.

```sh
PARKEZE_FEATURES="lorawan cellular wifi gnss"
```

Before this, everything was in `PACKAGES_COMMON` and every page was in every
console. The Opal carried a concentrator stack, ChirpStack and an uplink broker
for a radio it does not have; its console would have offered LoRaWAN settings
that could only fail.

## The words

| Word | Packages | Console | API | Needs |
|---|---|---|---|---|
| `lorawan` | `PACKAGES_LORAWAN`: parkeze-concentrator, chirpstack-gateway, spi-tools, gpiod-tools, mosquitto-ssl | LoRaWAN | `/api/lorawan/` | |
| `gnss` | none (parkeze-gps is in parkeze-concentrator) | GNSS | `/api/gnss` | `PARKEZE_GPS` not `none` |
| `bluetooth` | `PACKAGES_BLUETOOTH`: parkeze-ble | Bluetooth | `/api/bluetooth` | |
| `cellular` | `PACKAGES_CELLULAR`: parkeze-cellular, ModemManager, qmi-wwan; `PACKAGES_USB_CELLULAR` on a board with a USB host port | Backhaul > Cellular, Overview's Cellular card | `/api/network/cellular` | |
| `wifi` | `PACKAGES_WIFI`: parkeze-ap, wpad-openssl | Backhaul > WiFi, Access's setup AP | `/api/access/wifi`, `scan`, `ap`, `key` | |
| `lan` | `PACKAGES_LAN`: parkeze-lan | Network > LAN | `/api/lan/` | `PARKEZE_LAN_PORTS` |
| `dns` | `PACKAGES_DNS`: parkeze-dns | Network > DNS | `/api/dns/` | |
| `failover` | `PACKAGES_FAILOVER`: parkeze-uplinks | Network > Uplinks; Overview's Uplink row follows its order | `/api/uplinks/` | `cellular` or `wifi` |

Always present, on every board: Overview, Backhaul > Ethernet, Access, Panel,
Logs, System, the management tunnel, adoption, MQTT and the TUI.

`boards/common/board.conf` holds the list of words, each word's package group,
and two functions every caller shares:

- `parkeze_check_features` refuses an unknown word, a word whose "needs" the
  board does not meet (failover with nowhere to fail over to is one), and
  `PARKEZE_WAN_CELL_ENABLED=1` without `cellular`.
  `build.sh` and `scripts/check-deps.sh` both run it.
- `parkeze_packages` prints `PACKAGES_COMMON`, then each listed word's group,
  then `PACKAGES_BOARD`. `build.sh` and `scripts/check-deps.sh` both install
  from it, so the dependency check sees exactly what the image gets.

On the gateway, `PARKEZE_FEATURES` is in `/etc/parkeze/board.conf` with every
other `PARKEZE_` value. The console reads it from `GET /api/system/features`
(`system.features()` in `lib/system.uc`). Nav entries in `console/src/nav.ts`
carry a `feature`; the sidebar leaves out what the board lacks, `App.tsx` sends
the route home, and the API answers its endpoints `404 Not on this board.`
(`FEATURE_PREFIXES` in `api/index.uc`), because the scripts behind them are not
in the image and a missing binary otherwise surfaces as a 500.

## The boards

| Board | Features |
|---|---|
| `rpi3`, `rpi4`, `rpi5` | `lorawan cellular wifi gnss bluetooth` |
| `rak7268c`, `rak7289cv2` | `lorawan cellular wifi gnss` |
| `rak7268cv2` | `lorawan cellular wifi` (no GNSS) |
| `gl-sft1200` | `cellular lan dns failover` |

The Pi and RAK images were package-for-package what they were before the
feature list existed; the list only named what they already carried. The Pis
have since gained `PACKAGES_USB_CELLULAR` (below). The Opal
loses parkeze-concentrator, chirpstack-gateway, spi-tools, gpiod-tools,
mosquitto-ssl and parkeze-ap. It keeps `cellular` because a USB modem is its
second uplink, and has no `wifi` because its radios have only Siflower's
vendor driver.

RAK gateways never get the router set: their one port is the uplink and the
console at once (see [access.md](access.md)), and there is nothing to route
for.

## USB cellular is a board's, not a word

`PACKAGES_USB_CELLULAR` is the drivers for a modem somebody plugs in: MBIM,
AT ports, a Huawei stick, `usb-modeswitch`, and the USB Ethernet drivers and
`parkeze-usb-cellular` for a HiLink dongle or a tethered phone (see
[backhaul.md](backhaul.md), "Cellular adapters"). It is a group a board adds
to `PACKAGES_BOARD`, like the display and USB gadget groups, not a feature
word.

A word is what a board is for, and brings pages and endpoints with it. A USB
modem is the `cellular` feature's own page, endpoint and uplink, reached
through a different socket; what decides it is whether the board has a free
USB host port, which is hardware, the question the display and gadget groups
already answer per board. A word for it would have had no page to gate.

The Pis and the Opal take it. The RAK images do not: their modem is QMI and
soldered to their one USB port, and their flash is the tightest.
`parkeze_check_features` refuses `parkeze-usb-cellular` in `PACKAGES_BOARD`
without `cellular`, because it depends on parkeze-cellular and apk would
otherwise install the feature the board said it lacked.

## Packages that are not a feature's own

Some scripts are called from everywhere and live in parkeze-base, not in a
feature's package: `parkeze-backhaul-check` (adoption, the health gate, the
motd, the reset button, the console) moved there from parkeze-cellular so a
board without `cellular` still has it. `parkeze-gateway-facts` moved there
from parkeze-concentrator: `parkeze-claim report` sends its facts from every
gateway, and a board without `lorawan` that sent none was one parkeze.net
could not tell ran ParkezeOS. On such a board it reports
`concentrator=absent`. Everything else that reaches into a feature's package
already copes with it being absent: `parkeze-wifi-uplink` tests for
`parkeze-lora-route`, and the MQTT agent's ops fall back to `{}`.

`parkeze-boot-config` stays in parkeze-concentrator. It writes a Pi's
`config.txt`, every Pi has `lorawan`, and on a board without a Pi boot
partition the console's UART setting already reads it as absent.

## Adding a feature

1. Add the word to `PARKEZE_FEATURE_WORDS` and its line to the comment above
   it, and a `PACKAGES_<WORD>` group (empty is fine).
2. If it needs hardware, add the check to `parkeze_check_features`.
3. Add it to the `Feature` type in `console/src/types.ts`, put `feature` on its
   nav entries and wrap its routes in `Gated`.
4. Add its API prefix to `FEATURE_PREFIXES`.
5. List it on the boards that have it.

## What a router board may not do

The Opal is a Parkeze Net gateway like any other, and the devices on its LAN
are listed under it (logbook `docs/plans/connected-devices.md`, section 9).
Three rules follow, and every router page keeps them:

- **One way in.** Nothing opens a path from outside into the LAN except the
  tunnel forward net-api asks for (`lan-forward`, [lan.md](lan.md)). So there
  is no uplink port forward, no DMZ, no site VPN that reaches the LAN, and no
  firewall rule editor.
- **Policy is per MAC**: `parkeze` or `internet`, through `parkeze-lan policy`.
  No blocklist, no allowlist, no per-client speed limit.
- **Local is reported.** A setting changed at the gateway (a reservation, an
  upstream DNS server, the uplink order) is in the gateway's report to Parkeze
  Net, as the LAN's state already is (`parkeze-lan status`).

## DNS and Uplinks

Both follow Network > LAN: a tool on the gateway that owns the state and
prints it as JSON (`parkeze-dns`, `parkeze-uplinks`), a console module that
calls it (`lib/dns.uc`, `lib/uplinks.uc`), audited actions, and a read-only
MQTT op (`dns`, `uplinks`) that answers with the tool's `status`, as `lan`
answers with `parkeze-lan status`.

**DNS** is dnsmasq's UCI. Upstream is the uplinks' own servers, or up to three
named ones that replace them (`noresolv`); a list where none resolves Parkeze's
MQTT host is refused, because the gateway resolves through the same dnsmasq.
Local names are `domain` sections the LAN resolves. A name under a Parkeze
domain is refused: a client whose policy is `parkeze` may reach the addresses
dnsmasq answered for Parkeze's names (`parkeze_dst`), so such a name would hand
that client any address. So is a reservation's name, which parkeze-lan already
serves. Rebind protection stays on unless somebody turns it off, with the
domains allowed past it listed.

**Uplinks** sets each uplink's route metric from the order: 10, 20, 30, 40.
Tracking pings out of each tracked uplink's own device and, after `down`
misses, moves it behind the others (100 plus its step); `up` answers bring it
back. Ethernet is tracked by default, cellular only when turned on, and the
WiFi's health is parkeze-wifi-uplink's portal check. The tunnel's wired path
asks `parkeze-uplinks usable wan`, so it leaves a dead cable too. See
[backhaul.md](backhaul.md), "Failover".

Neither opens anything: a name and a metric reach nothing that was not
reachable before.

### On parkeze.net

net-api asks a gateway with a LAN for `uplinks` and `dns` on each lan-paths
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
the parts ParkezeOS takes are `lan`, `dns` and `failover`. What is taken is the
layout, not the prose: one page per concern, cards with their own Apply, a
status badge on the uplink carrying traffic. Every GL card opens with a
paragraph explaining itself, which this console does not do.

| GL.iNet | ParkezeOS |
|---|---|
| Internet: the Ethernet card (DHCP / static / PPPoE, VLAN, MTU) | Backhaul > Ethernet, on every board |
| Internet: Repeater | Backhaul > WiFi (`wifi`) |
| Internet: Cellular | Backhaul > Cellular (`cellular`) |
| Clients, LAN, DHCP, address reservation | Network > LAN (`lan`), built: `parkeze-lan status`, reserve, per-MAC policy, the open tunnel forwards read-only |
| Multi-WAN: priority, tracking, failover | Network > Uplinks (`failover`), built: the order, per-uplink tracking, the ping targets and thresholds; failover only, no load balance |
| DNS: hosts, upstream, rebind protection | Network > DNS (`dns`), built: automatic or custom upstream, local names, rebind protection and its allowed domains |
| Management Control | Access, already |
| Overview, Upgrade, Log, Time zone | System and Logs, already |

Left out, because each is a way into the LAN: port forwarding and DMZ,
WireGuard and OpenVPN servers and clients, LuCI's firewall rules. Left out
because nothing here needs them: guest network, network mode, drop-in
gateway, IGMP snooping, hardware acceleration, NAT mode, tethering, plug-ins,
NAS, GL's DDNS, GoodCloud and AstroWarp (parkeze.net is the fleet manager).

The management tunnel is the organization's when the organization has a hub
of its own; see [backhaul.md](backhaul.md), "Which hub". An Opal enrols the
same way every gateway does and needs nothing different for it.
