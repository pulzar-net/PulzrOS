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
| `cellular` | `PACKAGES_CELLULAR`: parkeze-cellular, ModemManager, qmi-wwan | Backhaul > Cellular, Overview's Cellular card | `/api/network/cellular` | |
| `wifi` | `PACKAGES_WIFI`: parkeze-ap, wpad-openssl | Backhaul > WiFi, Access's setup AP | `/api/access/wifi`, `scan`, `ap`, `key` | |
| `lan` | `PACKAGES_LAN`: parkeze-lan | Network > LAN | `/api/lan/` | `PARKEZE_LAN_PORTS` |
| `dns` | | planned: Network > DNS | | |
| `failover` | | planned: Network > Uplinks | | |

Always present, on every board: Overview, Backhaul > Ethernet, Access, Panel,
Logs, System, the management tunnel, adoption, MQTT and the TUI.

`boards/common/board.conf` holds the list of words, each word's package group,
and two functions every caller shares:

- `parkeze_check_features` refuses an unknown word, a word whose "needs" the
  board does not meet, and `PARKEZE_WAN_CELL_ENABLED=1` without `cellular`.
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

The Pi and RAK images are package-for-package what they were before the
feature list existed; the list only names what they already carried. The Opal
loses parkeze-concentrator, chirpstack-gateway, spi-tools, gpiod-tools,
mosquitto-ssl and parkeze-ap. It keeps `cellular` because a USB modem is its
second uplink, and has no `wifi` because its radios have only Siflower's
vendor driver.

RAK gateways never get the router set: their one port is the uplink and the
console at once (see [access.md](access.md)), and there is nothing to route
for.

## Packages that are not a feature's own

Two scripts are called from everywhere and live in parkeze-base, not in a
feature's package: `parkeze-backhaul-check` (adoption, the health gate, the
motd, the reset button, the console) moved there from parkeze-cellular so a
board without `cellular` still has it. Everything else that reaches into a
feature's package already copes with it being absent: `parkeze-claim` asks
`command -v parkeze-gateway-facts`, `parkeze-wifi-uplink` tests for
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

## The router set, from GL.iNet's

The Opal ships with GL.iNet's admin panel (firmware 4.8.3). Its feature
inventory, read off a stock unit, is in the router-features session's notes;
the parts ParkezeOS takes are the planned words above. What is taken is the
layout, not the prose: one page per concern, cards with their own Apply, a
status badge on the uplink carrying traffic. Every GL card opens with a
paragraph explaining itself, which this console does not do.

| GL.iNet | ParkezeOS |
|---|---|
| Internet: the Ethernet card (DHCP / static / PPPoE, VLAN, MTU) | Backhaul > Ethernet, on every board |
| Internet: Repeater | Backhaul > WiFi (`wifi`) |
| Internet: Cellular | Backhaul > Cellular (`cellular`) |
| Clients, LAN, DHCP, address reservation | Network > LAN (`lan`), built: `parkeze-lan status`, reserve, per-MAC policy, the open tunnel forwards read-only |
| Multi-WAN: priority, tracking, failover | Network > Uplinks (`failover`); failover only, no load balance |
| DNS: hosts, upstream, rebind protection | Network > DNS (`dns`) |
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
