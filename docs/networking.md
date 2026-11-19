# Networking

A gateway has up to three kinds of uplink and two ways to be managed. What separates them is cost: ethernet and WiFi are free, cellular is billed per megabyte.

## Uplinks

| Uplink | Interface | Route metric | Notes |
|---|---|---|---|
| Ethernet | `wan` | 10 | Always on. The same port is the console port. |
| WiFi | `wwifi` | 15 once it reaches the internet, 30 before | Joined from **Backhaul > WiFi**. |
| Cellular | `wwan`, or `usbwan` for a HiLink dongle or tethered phone | 20, 21 | APN and on/off in **Backhaul > Cellular**. |

On a board with the `failover` feature, **Network > Uplinks** sets the order instead, and tracking moves a dead uplink behind the others. Nothing is accepted from the WAN zone on any uplink.

Full detail: [Backhaul and management](/backhaul).

## WiFi uplink

Join a network from **Backhaul > WiFi**. The gateway does not trust a lease: it asks for a URL that answers 204 when the internet is really there, out of the WiFi device only, when the link comes up and once a minute after.

| State | Meaning | Used for the tunnel and LoRa |
|---|---|---|
| `open` | the internet answers | yes |
| `portal` | a sign-in page, a redirect or an intercepted certificate | no |
| `offline` | nothing answers | no |
| `unchecked` | not asked yet | no |

The WiFi page says why a network is not `open`, and keeps a roam history.

Which radio the uplink runs on, access points on the others, and a one-step repeater are on **Radios > WiFi**: [WiFi radios and repeaters](/radios).

## Captive portals

A guest network that wants somebody to click through a sign-in page has to see the *gateway* click, since a portal admits a device by its MAC. So **Sign in** on the WiFi page opens the portal's page as the gateway: a proxy on the gateway fetches it out of the WiFi radio and hands it to your browser, wherever that browser is (cable, setup AP, or the cloud with the gateway on cellular). The terminal UI shows the same sign-in as a URL and a QR code.

Some portals cannot be followed this way: one that checks its own hostname in script, or needs a client certificate. Where the site offers device registration, register the MAC the WiFi page shows instead.

How the proxy is isolated from the console: [Setup access](/access#signing-the-gateway-in-to-a-wifi-portal).

## Cellular

Built-in modems (RAK units with LTE) and USB adapters on boards with a free USB host port: QMI, MBIM and AT modems, Huawei sticks, HiLink dongles and tethered phones. ModemManager drives `wwan` whatever the modem speaks.

`pulzr-cellular-watchdog` brings the link back on its own: it notices a session that carries nothing and a modem that has given up after a refused attach.

LoRaWAN uplinks may use cellular when the wired uplink is down (**LoRaWAN > Settings**). The management tunnel does not ride cellular by default; a cellular gateway is reached through the SIM provider's network instead.

## Management paths

The cloud reaches a gateway one of two ways:

1. A **WireGuard tunnel** (`wg0`) over ethernet or open WiFi. Free, and the default.
2. The **SIM's own address** through the cellular provider's VPN, when the tunnel is not up.

The tunnel is marked so it can never leave on a metered link. See [Backhaul and management](/backhaul#the-management-tunnel).

## Router boards

A board with the `lan` feature (the GL.iNet Opal) routes for devices on its LAN ports: DHCP, reservations, per-device policy, a per-device cellular rule, and ports exposed on the wired or WiFi uplink only. Customer traffic never rides the management tunnel or the SIM.

- [LAN ports](/lan)
- [Ports and VLANs](/ports)
- [Speed tests](/speedtest)
- [Board features](/features#dns-and-uplinks): DNS and uplink tracking
