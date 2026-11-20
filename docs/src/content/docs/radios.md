---
title: "WiFi radios and repeaters"
description: "The uplink's network is still managed on Backhaul > WiFi: saved networks, 802.1X, roaming and the portal check."
---

**Radios > WiFi** in the console lists every WiFi radio on the gateway, shows what runs on each one, and lets you change it. The page is there on any board built with the `wifi` feature. It lists the radios the board actually has (each UCI `wifi-device` whose phy is present), so a board with no WiFi has no page.

The uplink's network is still managed on **Backhaul > WiFi**: saved networks, 802.1X, roaming and the portal check. This page decides which radio the uplink runs on and what the other radios do.

## The topology

At the top of the page the gateway's WiFi is drawn as a path, left to right:

```
Internet ── Site-Ops ──[2.4 GHz, Radio 1, ch 6]── gateway ──[5 GHz, Radio 2, ch 36]── Shop Floor  (LAN, 3 clients)
                                                          └─[5 GHz, Radio 2, ch 36]── Cameras     (LAN, 1 client)
```

- **Left:** what the gateway reaches the internet through. That is the WiFi uplink, a client of the site's network, with its signal and the portal check's state. If traffic goes out another way, that uplink is drawn too (Ethernet or cellular). An uplink stopped at a sign-in page is drawn dashed amber and has a **Sign In** button. The button uses the same proxy as the WiFi page.
- **Middle:** the gateway and its radios, each in its band's colour (2.4 GHz amber, 5 GHz indigo, 6 GHz violet).
- **Right:** every access point and mesh, on the radio it runs on, with its network and the number of connected clients.

A hop that is a radio is labelled with its band, radio and channel, so a two-radio repeater reads at a glance. A live radio hop pulses; a dashed hop is down (red) or off (grey). The gateway's badge says what it is doing: **Repeater** (an uplink and an access point), **Access point**, **WiFi client** or **Radios idle**.

On a phone the path runs down the screen instead.

## Each radio

Below the topology there is one card per radio. Each card shows:

- the band, channel, width and transmit power;
- the chip, as iwinfo names it;
- every interface on the radio, with its role.

| Role | What it is | Changed from |
|---|---|---|
| Uplink | the WiFi uplink's station (`parkeze_sta`) | Backhaul > WiFi; **Use for Uplink** moves it here |
| Access point | an SSID onto a LAN-side network (`pulzr_ap_<n>`) | this page: edit, remove |
| Setup network | the setup AP (`parkeze_ap`, `pulzr-ap`) | Access |
| Mesh, monitor, client | anything made by hand | shown only |

An access point's row opens to its clients: MAC address, maker (looked up only while the uplink in use is not metered, as on the LAN page), signal and rate.

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

## Repeater setup

**Set Up Repeater** does it in one step: one radio joins the site's network as the uplink, and another serves the gateway's own network.

1. Choose the uplink radio and the access point radio. On a two-radio router, 2.4 GHz for the uplink usually reaches further. 5 GHz for the access point gives its clients more throughput.
2. Keep the network the uplink is on now, or choose another. **Another network** opens the join wizard from Backhaul > WiFi, with its scan, passphrase, 802.1X and certificate check, on the radio you chose.
3. Name the new network and give it a passphrase.

The upstream join and the access point are one change. Both are checked before anything is written, so a refusal changes nothing. The join is a normal join: the network is saved, roaming and the portal check apply, and **Sign In** works from either page.

### One radio

Some radios can be a station and an access point at once. Then the access point **follows the uplink's channel**: one radio has one channel, and the upstream network chooses it. The radio card shows the channel as following the uplink, and the channel setting has no effect while the uplink is joined. The access point comes up once the uplink has associated.

Whether a radio can do this is read from the radio itself (see below). A Raspberry Pi 3 can run one station and one AP. A radio that runs only one interface at a time cannot, and the page says to use two radios.

### Moving the uplink

**Use for Uplink** on another radio moves the uplink there by rejoining its saved network on that radio. Without a WiFi uplink yet, it opens the join wizard for that radio. A rejoin from Backhaul > WiFi, and a roam, keep the uplink on the radio it is on.

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
3. The console confirms once it reaches the gateway again over a new connection, no sooner than 15 seconds after.
4. If nothing confirms within 90 seconds, the old configuration comes back and the radios reload. A reboot inside the window undoes the change at boot. **Undo Now** puts it back at once.

So a channel change that drops the laptop you are working from, or an uplink moved onto a radio that cannot reach the site's network, undoes itself.

## API

| Route | Does |
|---|---|
| `GET /api/radios` | the radios, their interfaces and clients, what each radio allows, the networks an AP may use, the route |
| `POST /api/radios/radio` | `{radio, channel, width, txpower, country, enabled}` |
| `POST /api/radios/ap` | `{id?, radio, ssid, security, key, network, hidden, isolate, enabled, allowOpen}` |
| `POST /api/radios/ap/remove` | `{id}` |
| `POST /api/radios/uplink` | a join (as `POST /api/access/wifi`) with `radio`, and optionally `ap` for a repeater |

All of them need a session and the CSRF header, and every POST answers with the rollback window (`pending`). Every change is audited (`radio.set`, `radio.ap.add`, `radio.ap.edit`, `radio.ap.remove`, `radio.uplink`, `radio.repeater`). Tests: `scripts/test-radios.sh`.
