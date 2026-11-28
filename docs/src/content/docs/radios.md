---
title: "WiFi radios and repeaters"
description: "The uplink's saved networks, 802.1X, roaming and the portal check stay on Backhaul > WiFi."
---

The console's **Network** page shows every WiFi radio on the gateway beside its Ethernet ports, what runs on each one, and lets you change it. Its WiFi part is there on any board built with the `wifi` feature. It lists the radios the board actually has (each UCI `wifi-device` whose phy is present), so a board with no WiFi has none.

The uplink's saved networks, 802.1X, roaming and the portal check stay on **Backhaul > WiFi**. The Network page decides which radio the uplink runs on and what the other radios do, and leaves or changes the uplink's network.

## The diagram

At the top of the page the gateway is drawn as Pulzr Cloud's Topology draws one (React Flow, the same cards), left to right:

```
Internet ── WAN        (No cable)                   ── gateway ── LAN 1        (100 Mb/s, 1 client)
         ── Site-Ops   (2.4 GHz, ch 6, -61 dBm) In Use          ── Shop Floor  (5 GHz, ch 36, 3 clients)
         ── Cellular   (Online)                                 ── 6 GHz Radio (Off)
```

- **Left:** every uplink: a port whose role is uplink, each WiFi station, the modem. The one carrying traffic is marked **In Use** and drawn heavy; a standby one is dashed, one that is down dotted.
- **Middle:** the gateway, by its name and LAN address.
- **Right:** every LAN port with its speed and clients, every access point and mesh with its band, channel and clients, and every radio running nothing.

A WiFi card and its line are in its band's colour (2.4 GHz amber, 5 GHz indigo, 6 GHz violet). A port opens its role and VLANs; a WiFi card opens its radio's settings.

## The WiFi uplink

Below the client list, the network the uplink is on, with its band, channel, signal and address:

- **Disconnect** leaves it and keeps it saved (`POST /api/access/wifi/forget` with `keep`). Nothing rejoins it on its own: roaming needs a station. **Join** with its name then puts it back without the password.
- **Change Network** scans, lists what is in range, and joins the one picked with the password typed (the join wizard, as on Backhaul > WiFi).
- **Sign In** while the network wants a sign-in page or answers nothing.

## Each radio

Below the uplink there is one card per radio. Each card shows:

- the band, channel, width and transmit power;
- the chip, as iwinfo names it;
- every interface on the radio, with its role.

| Role | What it is | Changed from |
|---|---|---|
| Uplink | the WiFi uplink's station (`pulzr_sta`) | Backhaul > WiFi |
| Uplink | a second radio's WiFi uplink (`pulzr_sta2`, interface `wwifi2`) | this page: **Use for Uplink**, remove |
| Access point | an SSID onto a LAN-side network (`pulzr_ap_<n>`) | this page: edit, remove |
| Setup network | the setup AP (`pulzr_setup_ap`, `pulzr-ap`) | Setup Access Point, on the same page |
| Mesh, monitor, client | anything made by hand | shown only |

An access point's row opens to its clients: MAC address, maker (looked up only while the uplink in use is not metered, as in the client list), signal and rate.

**Settings** on a radio sets:

- **Radio on or off.**
- **Channel:** automatic, or one the radio allows in this country. A channel that cannot carry the chosen width cannot be picked. DFS channels are marked.
- **Width:** 20, 40, 80 or 160 MHz, as far as the radio and band go. Wider widths use the radio's newest standard (HE, else VHT, else HT).
- **Transmit power:** maximum, or a fixed dBm up to the channel's limit.
- **Country:** set on every radio at once. Linux has one regulatory domain, however many radios there are.

## Access points

**Add Access Point** asks for:

- a name;
- the security: WPA2, WPA2/WPA3, WPA3 or open (the WPA3 options appear only when the gateway's wpad supports SAE);
- a passphrase;
- the network to bridge onto;
- whether the SSID is hidden;
- whether clients are kept apart from each other.

An access point can only go on a LAN-side network. Today that is the LAN (`devlan`, with every port VLAN that serves devices, [Ports and VLANs](/PulzrOS/ports.html)). Bridging an AP onto an uplink would put that uplink's far side in reach of anybody nearby. On a board with no LAN there is nothing to serve, and the page offers no access point.

An open access point puts the LAN in reach of anybody in range: the PLC, the cameras, the console. The gateway refuses one unless it is confirmed explicitly, the same rule it applies to an open uplink.

When you edit an access point, a blank passphrase keeps the current one. The gateway never sends a passphrase back to the console.

## Repeater

A repeater is a network joined on one radio and another broadcast on a different radio. Join the site's network (Backhaul > WiFi, or **Use for Uplink** on a radio), then **Add Access Point** on a radio that is not joined to anything. There is no separate repeater button.

### Switch to Access Point

A radio carrying a WiFi uplink offers **Switch to Access Point** instead of **Add Access Point**. It asks what an access point does, and then takes the uplink's station off that radio and writes the access point in one change (`POST /api/radios/ap` with `replace`), so one undo brings the uplink back. As two changes, the first would cut off a gateway whose only way home is that WiFi before the second was asked for. The network stays saved. The station goes to the back of the uplink order first, so the traffic is on whatever is next before it lets go. On a two-radio router, 2.4 GHz for the uplink usually reaches further, and 5 GHz for the access point gives its clients more throughput.

### Another radio as the uplink

**Use for Uplink** on a radio with no station joins that radio as a second WiFi uplink, onto the network the uplink is on now or another one (**Another network** opens the join wizard for that radio). The network the uplink is on now is offered only when that radio hears it (`GET /api/radios/scan?radio=`). A site whose 5 GHz network has a name of its own gets "Charter is not heard on 5 GHz." and the join wizard, listing what the 5 GHz radio hears. Without a WiFi uplink yet, it opens the join wizard. The wizard for a chosen radio always lists that radio's scan. A rejoin from Backhaul > WiFi, and a roam, keep the uplink on the radio it is on.

The old uplink keeps carrying the traffic until the new one is proven. This is make-before-break:

| Step | What happens | The old radio |
|---|---|---|
| 1 | The second station (`pulzr_sta2`, `wwifi2`) is written beside the first, at metric 200, behind every uplink. Only its own radio restarts. | carries traffic |
| 2 | It associates and gets a lease. `pulzr-wifi-uplink check wwifi2` asks whether it reaches the internet, out of its own device. | carries traffic |
| 3 | Once the answer is open, the handover puts `wwifi2` where the old WiFi uplink is in the uplink order, with the old one right behind it. `pulzr-uplinks` moves the metrics, then the tunnel and LoRa routing with one route replace each. | still associated |
| 4 | The old station stays as the next uplink to fail over to. | fallback |

If the new station is not open within two minutes, it is removed again and the page says why: wpa_supplicant's reason when it never associated (a wrong passphrase, the network not found), or the portal check's step when it did. Nothing about the old uplink changes.

Each WiFi uplink has its own portal check answer (`/var/run/pulzr/wifi-uplink.json` for `wwifi`, `wifi-uplink-wwifi2.json` for `wwifi2`), and `pulzr-uplinks` judges each by its own answer. A WiFi `ifup` no longer restarts the tunnel when `wg0` is up. A restart deletes `wg0`, so a second radio coming up would drop the tunnel the first radio was carrying.

A gateway has at most two WiFi uplinks. Each is its own entry in the uplink order on Backhaul (**WiFi** and **WiFi 2**), dragged on its own, and each is judged by its own portal check on Tracking. Roaming and portal sign-in belong to the first (Backhaul > WiFi). A second uplink is removed from its row's remove button: it moves to the back of the uplink order first, so the traffic is on the other uplink before it lets go.

## What the hardware allows

The console does not keep a table of chips. It reads each radio's phy with `iw phy <phy> info`. `iw` is in every WiFi board's image (`PACKAGES_WIFI`). The gateway reads:

- the channels open in this regulatory domain, with their power limits and DFS flags;
- the widths the radio supports on its band (HT40, VHT, VHT160, HE40/80/160, EHT320);
- its interface combinations, for example `#{ managed } <= 1, #{ AP } <= 1, total <= 2, #channels <= 1`.

Every change is checked against these before it is written. The gateway refuses an access point, an uplink move or a repeater that the combinations do not allow, a channel the domain closes, and a width the channel cannot carry, and it says why. Without this check the change would be written, hostapd would fail on it, and nobody would see why.

## Apply and rollback

Every change on this page goes through `pulzr-apply`, the same window that protects the other network settings ([Ports and VLANs](/PulzrOS/ports.html#kept-only-once-confirmed)):

1. The API arms the window, which keeps `/etc/config/wireless`, `network`, `firewall`, `dhcp` and `pulzr` as they were.
2. The change is written, and the radios reload two seconds later, so the answer reaches the browser before the radio it is on goes down.
3. The console confirms once it reaches the gateway again over a new connection, no sooner than 15 seconds after. A join (**Use for Uplink**, **Change Network**) is also kept by the gateway as soon as the new station's portal check says open.
4. If nothing confirms within 90 seconds (150 for a join), the old configuration comes back and the radios reload. A reboot inside the window undoes the change at boot. **Undo Now** puts it back at once.

So a channel change that drops the laptop you are working from, or an uplink moved onto a radio that cannot reach the site's network, undoes itself.

## API

| Route | Does |
|---|---|
| `GET /api/radios` | the radios, their interfaces and clients, what each radio allows, the networks an AP may use, the route, every WiFi uplink (`uplinks`) and the latest handover (`handover`) |
| `POST /api/radios/radio` | `{radio, channel, width, txpower, country, enabled}` |
| `POST /api/radios/ap` | `{id?, radio, ssid, security, key, network, hidden, isolate, enabled, allowOpen, replace?}`; `replace` takes the WiFi uplink off that radio in the same change |
| `POST /api/radios/ap/remove` | `{id}` |
| `GET /api/radios/scan?radio=` | the networks that radio hears, as `GET /api/access/scan` answers |
| `POST /api/radios/uplink` | a join (as `POST /api/access/wifi`) with `radio`; onto a radio with no station while another has one, a second uplink and a handover. `ap` still writes an access point with it (no page sends it now) |
| `POST /api/radios/uplink/remove` | `{radio}`: the second WiFi uplink off that radio |

All of them need a session and the CSRF header, and every POST answers with the rollback window (`pending`). Every change is audited (`wifi.disconnect`, `radio.set`, `radio.ap.add`, `radio.ap.edit`, `radio.ap.remove`, `radio.uplink`, `radio.uplink.remove`, `radio.repeater`). Tests: `scripts/test-radios.sh`.
