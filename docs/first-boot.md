# First boot and access

The first boot takes a minute or two while the gateway generates its identity, its console certificate and its one-time password. Most installs never connect to it locally: plugged into anything with a route out, it registers itself and waits in the cloud's pending list, where the installer adopts it by the EUI on the label.

Everything below is for when that has not happened.

## Ways in

| | How | Notes |
|---|---|---|
| **Ethernet** | `https://pulzr-<serial>.local`, `https://pulzr.local`, or `https://192.168.61.1` | The uplink port is also the console port, always. The gateway never serves DHCP on it; your laptop self-assigns a link-local address. |
| **LAN port** | `https://192.168.64.1` | Boards with LAN ports only. These serve DHCP. See [LAN ports](/lan). |
| **USB cable** | `https://pulzr.local` | Pi 4 and Pi 5, on the USB-C power port. The cable is a network. |
| **Serial** | 115200 8N1 on a Pi's header; 57600 on a RAK's USB-C console socket | The terminal UI, behind the console's sign-in. |
| **SSH** | `ssh pulzr@<gateway>` | The terminal UI as an unprivileged user. No shell. |
| **HDMI** | a screen attached at boot (Pi) | The terminal UI, behind the console's sign-in. |
| **Setup AP** | four presses of the reset button | Only when no uplink works. See below. |

## The password

On a Pi, the initial password is on the card's boot partition as `pulzr-initial-password.txt`; the card mounts on any laptop. To set your own before first boot, write `pulzr-password.txt` there: it is applied and deleted. The serial banner prints the console address and the initial password too.

The console will not let you past the initial password without changing it. Once a gateway is adopted, local passwords stop working: sign in with your cloud account, or with offline recovery when the gateway has no uplink. See [Authentication and SSH](/auth).

## The reset button

| Press | Result |
|---|---|
| One, under 2 s | status on the cloud LED, or the status LED without one |
| Four, under 2 s each, at most 2.5 s apart | setup mode |
| Held past 10 s (every light comes on) | factory reset |
| Anything else | nothing |

**Setup mode** raises an access point for 30 minutes, but only when no uplink works. Join `Pulzar-<six hex>`, open `https://192.168.62.1`, sign in, and go to **Backhaul > WiFi**. If an uplink does work, nothing is raised and the lights flash fast for six seconds: the console is reachable the usual way. On an adopted gateway the AP's passphrase is on the gateway's page in the cloud and on its own Access page.

Turn the gesture off with `pulzr.ap.button=0` (Access page). The full design, and why the ethernet port is the primary way back in, is in [Setup access](/access).

## Re-flashing a card

A card that ran PulzrOS before comes up clean: the image is padded so writing it covers the old overlay. A gateway that still shows old settings after an upgrade needs:

```sh
firstboot -y && reboot
```

See [Flashing](/flashing#re-flashing-a-card-that-has-run-pulzaros-before).
