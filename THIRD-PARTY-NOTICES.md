# Third-party notices

PulzarOS is an OpenWrt distribution. This repository holds PulzarOS's own code
(Apache-2.0, see [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE)); building it
downloads and assembles the components below into a firmware image. The licence
of each component applies to that component, and to the image as a whole in the
way the licence says.

## In the images

| Component | Licence | Where it comes from |
|---|---|---|
| OpenWrt (kernel, base system, ImageBuilder, procd, netifd, uhttpd, ubus, uci, ...) | GPL-2.0-only, with individual components under their own licences (ISC, MIT, BSD, LGPL, ...) | `downloads.openwrt.org`, pinned by `OPENWRT_VERSION` and verified by sha256 |
| ucode and its modules, umdns, uhttpd, libubox | ISC | OpenWrt feed |
| dnsmasq-full, hostapd/wpad, ModemManager, WireGuard tools, nftables, openssh, dropbear, mosquitto, curl, jq and the other packages named in `boards/*/board.conf` | each package's own licence (GPL-2.0, GPL-2.0-or-later, LGPL-2.1, BSD, EPL-2.0/EDL-1.0, MIT/curl, ...) | OpenWrt feeds |
| librespeed-cli | LGPL-3.0 | OpenWrt feed |
| Linux kernel and firmware blobs for the Raspberry Pi and RAK boards | GPL-2.0-only; firmware under its vendors' redistribution licences | OpenWrt and the board targets |
| ChirpStack Concentratord, ChirpStack MQTT Forwarder (`feed/chirpstack-gateway`) | MIT | `artifacts.chirpstack.io`, and the ChirpStack Gateway OS image for the MIPS build, pinned by sha256 in `feed/chirpstack-gateway/fetch` |
| Semtech SX1301/SX1302 HAL (inside Concentratord) | BSD-3-Clause | ChirpStack |
| ChirpStack region and channel plans (`region.toml`, `channels.toml`) | MIT | ChirpStack Concentratord |

Corresponding source for the GPL components is the OpenWrt source tree for the
release named in `boards/common/board.conf` (`OPENWRT_VERSION`), available from
<https://openwrt.org> and <https://git.openwrt.org>. Anyone redistributing an
image built from this repository takes on the same obligation and should keep
that source available.

## In the repository

| File | Licence | Note |
|---|---|---|
| `boards/common/files/etc/hotplug.d/tty/25-modemmanager-tty` | GPL-2.0-only | A modified copy of OpenWrt's modemmanager hotplug script (Velocloud Inc, Aleksander Morgado); it replaces the package's copy at image assembly and stays under its original licence |
| `feed/pulzr-base/files/usr/share/pulzr/fonts/slant.flf` | FIGlet font licence (modification permitted with the modifier named in a comment) | "Slant", Glenn Chappell, Paul Burton |
| `feed/pulzr-base/files/usr/sbin/pulzr-figlet` | Apache-2.0 | A renderer written against FIGlet's published layout rules; tested for identical output against figlet 2.2.5 (BSD-2-Clause) in `scripts/test-figlet.sh`, which is not shipped |
| `feed/pulzr-concentrator/files/usr/sbin/pulzr-sx130x-reset` | Apache-2.0 | The reset sequence follows Semtech's `reset_lgw.sh` reference design (BSD-3-Clause) |
| `feed/pulzr-concentrator/files/usr/share/pulzr/region/*/region.toml`, `channels.toml` | MIT | ChirpStack Concentratord examples, unmodified |

## The console (`console/`)

Built to static files at image build time and served by uhttpd.

| Package | Licence |
|---|---|
| react, react-dom | MIT |
| react-router-dom | MIT |
| @tanstack/react-query, @tanstack/react-table | MIT |
| lucide-react | ISC |
| uPlot | MIT |
| vite, @vitejs/plugin-react | MIT |
| typescript (build only) | Apache-2.0 |

`console/package-lock.json` pins every transitive dependency; their licences are
in each package's own `LICENSE`.

## Boards that build from source

`docs/boards.md` describes boards whose OpenWrt support lives in separate
`openwrt-<board>` repositories (GPL-2.0-only, with their vendors' drivers, for
example the Siflower Wi-Fi driver, GPL-2.0).
