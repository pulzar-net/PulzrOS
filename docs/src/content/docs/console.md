---
title: "Console guide"
description: "The console is a web app the gateway serves itself, over HTTPS, from its ethernet port, LAN ports, USB cable or setup AP."
---

The console is a web app the gateway serves itself, over HTTPS, from its ethernet port, LAN ports, USB cable or setup AP. There is no LuCI. The [terminal UI](/PulzrOS/tui.html) has the same pages for serial, SSH, HDMI and USB.

A page appears only on a board built with its feature: a router has no LoRaWAN page, and a RAK unit has no LAN clients on Network. The feature list per board is on each [hardware page](/PulzrOS/hardware.html).

## Signing in

| Gateway state | Sign in with |
|---|---|
| Unadopted | the local password (initial password first, then yours) |
| Adopted, online | your cloud account |
| Adopted, offline | offline recovery: a challenge the cloud signs, read off a phone |

Why it works this way is in [Authentication and SSH](/PulzrOS/auth.html).

## Pages

### Overview

The gateway at a glance: uplink in use, LoRaWAN and radio state, CPU, memory and load, the PulzrOS version and uptime.

### Connectivity

| Page | What you do there | Feature |
|---|---|---|
| **Backhaul** | every connection in failover order with its link, signal, address, last speed test and last check, which one is in use; drag to set the order, a speed test of each; the management tunnel to Pulzr Cloud | every board; ordering with `failover` |
| **Backhaul > Ethernet** | DHCP or a static address on each wired uplink, and its VLAN | every board |
| **Backhaul > Cellular** | APN, on or off, signal and the modem's state; which SIM slot on a modem with several | `cellular` |
| **Backhaul > WiFi** | scan and join a network, see why it is not online, sign in to a captive portal | `wifi` |
| **Backhaul > Tracking** | tracking on or off per uplink, its ping targets and thresholds | `failover` |
| **Network** | the case's face (antennas, modem, power, every jack lit by its link and marked with its role, as Pulzr Cloud draws it), then one diagram of the gateway: the internet, every uplink (WAN port, WiFi station, modem) with the one in use marked, and every LAN port, access point and idle radio with its link speed, or band, channel and signal. A port opens its role and VLANs, a radio its settings. Below it every client, wired and WiFi, with its port or SSID and band, address, name or maker, policy, reservation and cellular rule; then the WiFi uplink (**Disconnect**, **Change Network**, rejoin the last network), each radio and what runs on it (access points, a second uplink, **Switch to Access Point**), and the setup access point. Every change is undone unless confirmed. | every board; WiFi with `wifi`, clients with `lan` or `wifi` |
| **Network > Tunnels** | WireGuard tunnels to a customer's own servers: what each reaches, the internet through it | `lan` |
| **Network > Port Forwarding** | exposed ports on the uplinks, and the tunnel forwards Pulzr Cloud opens | `lan` |
| **Network > DNS** | upstream servers, local names, rebind protection, dynamic DNS | `dns` |
| **Network > Speed Test** | a test out of each uplink, never cellular | `speedtest` |

Details: [Networking](/PulzrOS/networking.html), [Setup access](/PulzrOS/access.html).

### Radios

| Page | What you do there | Feature |
|---|---|---|
| **LoRaWAN > Forwarders** | each concentrator slot: detected part, gateway ID, packets, the LNS broker it publishes to | `lorawan` |
| **LoRaWAN > Settings** | region plan, bus and reset line on kit boards, uplink delivery over cellular | `lorawan` |
| **Bluetooth** | the adapter and what it forwards | `bluetooth` (the pulzr-ble add-on) |
| **GNSS** | receiver, live fix and recorded position | `gnss` |

On fixed hardware (RAK units) the radio settings are read-only: the hardware cannot change. Details: [Concentrators and GNSS](/PulzrOS/concentrators.html), [Bluetooth](/PulzrOS/bluetooth.html), [WiFi radios and repeaters](/PulzrOS/radios.html).

### Gateway

| Page | What you do there |
|---|---|
| **Panel** | each light on the board and what it shows now, the blink codes, the reset button; only on a board with LEDs |
| **Logs** | the system log, filtered and followed live |
| **System > Resources** | CPU, memory, temperature, storage, processes |
| **System > Maintenance** | firmware upgrade, the local password, add-ons, reboot |

Upgrading from the console: [Firmware updates and signing](/PulzrOS/firmware.html).

## Developing the console

The console is React, built to static files by `build.sh` and served by uhttpd over a ucode API.

```bash
cd console
npm install
npm run typecheck
PULZR_GATEWAY=https://<gateway-ip> npm run dev   # against a real gateway
```

Its text follows the rules in [`CLAUDE.md`](https://github.com/pulzar-net/PulzrOS/blob/main/CLAUDE.md): no subtitles, no explanatory paragraphs on screen, no emoji, write for a technician.
