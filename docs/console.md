# Console guide

The console is a web app the gateway serves itself, over HTTPS, from its ethernet port, LAN ports, USB cable or setup AP. There is no LuCI. The [terminal UI](/tui) has the same pages for serial, SSH, HDMI and USB.

A page appears only on a board built with its feature: a router has no LoRaWAN page, and a RAK unit has no LAN page. The feature list per board is on each [hardware page](/hardware/).

## Signing in

| Gateway state | Sign in with |
|---|---|
| Unadopted | the local password (initial password first, then yours) |
| Adopted, online | your cloud account |
| Adopted, offline | offline recovery: a challenge the cloud signs, read off a phone |

Why it works this way is in [Authentication and SSH](/auth).

## Pages

### Overview

The gateway at a glance: uplink in use, LoRaWAN and radio state, resources, firmware version, OpenWrt and kernel.

### Connectivity

| Page | What you do there | Feature |
|---|---|---|
| **Backhaul > Ethernet** | DHCP or a static address on each wired uplink, and its VLAN | every board |
| **Backhaul > Cellular** | APN, on or off, signal and the modem's state | `cellular` |
| **Backhaul > WiFi** | scan and join a network, see why it is not online, sign in to a captive portal | `wifi` |
| **Network > Ports** | each port an uplink, a LAN port or unused; tagged VLANs. Undone unless confirmed. | every board |
| **Network > LAN** | clients, reservations, per-device policy and cellular rule, exposed ports | `lan` |
| **Network > Uplinks** | uplink order, health tracking and failover | `failover` |
| **Network > DNS** | upstream servers, local names, rebind protection, dynamic DNS | `dns` |
| **Network > Speed Test** | a test out of each uplink, never cellular | `speedtest` |
| **Access** | the setup access point and its passphrase, the management tunnel | every board |

Details: [Networking](/networking), [Setup access](/access).

### Radios

| Page | What you do there | Feature |
|---|---|---|
| **LoRaWAN > Forwarders** | each concentrator slot: detected part, gateway ID, packets, the LNS broker it publishes to | `lorawan` |
| **LoRaWAN > Settings** | region plan, bus and reset line on kit boards, uplink delivery over cellular | `lorawan` |
| **Bluetooth** | the adapter and what it forwards | `bluetooth` |
| **GNSS** | receiver, live fix and recorded position | `gnss` |

On fixed hardware (RAK units) the radio settings are read-only: the hardware cannot change. Details: [Concentrators and GNSS](/concentrators), [Bluetooth](/bluetooth).

### Gateway

| Page | What you do there |
|---|---|
| **Panel** | each light on the board and what it shows now, the blink codes, the reset button |
| **Logs** | the system log, filtered and followed live |
| **System > Resources** | CPU, memory, temperature, storage, processes |
| **System > Maintenance** | firmware upgrade, the local password, add-ons, reboot |

Upgrading from the console: [Firmware updates and signing](/firmware).

## Developing the console

The console is React, built to static files by `build.sh` and served by uhttpd over a ucode API.

```bash
cd console
npm install
npm run typecheck
PULZR_GATEWAY=https://<gateway-ip> npm run dev   # against a real gateway
```

Its text follows the rules in [`CLAUDE.md`](https://github.com/pulzar-net/PulzrOS/blob/main/CLAUDE.md): no subtitles, no explanatory paragraphs on screen, no emoji, write for a technician.
