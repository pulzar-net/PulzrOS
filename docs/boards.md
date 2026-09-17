# Adding a board

The design goal is that a new board is **a page of deltas, not a fork**. If you
find yourself copying more than about twenty lines out of
`boards/common/board.conf`, the thing you copied belongs in common.

## What a board owns

Only what is genuinely different about the hardware:

- the OpenWrt target, subtarget, profile and architecture
- board-specific kernel modules (`PACKAGES_BOARD`)
- which GPIO the concentrator's reset and power-enable lines are on
- whether the concentrator is fixed or has to be probed, and in what order
- any default that differs (LAN address, region, whether ethernet WAN is on)

Everything else — the console, the auth model, the network shape, tunnel
confinement, the LoRa stack — is shared and must not be duplicated.

## Steps

1. `mkdir boards/<id>` and write `board.conf`, sourcing common first:

   ```sh
   . "${BOARDS_DIR}/common/board.conf"

   BOARD_ID="myboard"
   BOARD_NAME="My Board"
   OPENWRT_TARGET="..."
   OPENWRT_SUBTARGET="..."
   OPENWRT_PROFILE="..."      # `./build.sh --list` won't tell you this;
                              # see the OpenWrt target's profiles list
   OPENWRT_ARCH="..."
   ```

2. Add board-specific kernel modules to `PACKAGES_BOARD`.

3. Declare the concentrator slots. See `docs/concentrators.md` for the model:

   - **Fixed hardware** (a RAK unit, a CM carrier): list each slot explicitly,
     e.g. `PARKEZE_CONCENTRATOR_SLOTS="spi:/dev/spidev0.0:17"`, and set
     `PARKEZE_CONCENTRATOR_CONFIGURABLE="0"`.
   - **A kit** (a Pi): `PARKEZE_CONCENTRATOR_SLOTS="auto"`. Every bus is
     probed and everything stays operator-editable.

4. Map the LEDs and the button. `PARKEZE_LED_*` take names from
   `/sys/class/leds`, and the only reliable way to fill them in is to look on
   the running board — `parkeze-led --list` prints both the map and what the
   kernel actually exposes, and `parkeze-led --test` walks them so a wrong name
   is obvious in ten seconds. A board with fewer LEDs simply leaves names
   unset; `parkeze-io-daemon` folds their state into the ones that exist rather
   than pretending the board has more lights than it does.

5. Optionally add `boards/<id>/files/` for literal files to overlay. These win
   over `boards/common/files/`.

6. `./build.sh <id>`.

## Adding a concentrator, not a board

Drop a JSON file into
`feed/parkeze-concentrator/files/usr/share/parkeze/concentrator/`. That is the
whole of it — the console's hardware menu is built by reading that directory,
so a new profile appears as a selectable option with no UI change and no SPA
rebuild.

See the README in that directory for the field meanings. The important
discipline: a profile describes **the part**, not the board and not the region.
Board facts live in `board.conf`, regional facts in the region plan. Keeping the
three apart is what lets a Pi 3 + WM1302 in the US and a RAK7268 in the EU share
every line of code.

If the part is on a bus the probe cannot interrogate (today: UART — see
`sx130x_probe`), set the profile's `interface` accordingly; the console will
label it "manual only" rather than letting somebody select it and then wonder
why detection disagrees.

## The current boards

| Board | Target | Concentrator | Status |
|---|---|---|---|
| `rpi3` | bcm27xx/bcm2710 | 1 slot, `auto` | Kit. Any bus. |
| `rpi4` | bcm27xx/bcm2711 | 1 slot, `auto` | Kit. Any bus. |
| `rpi5` | bcm27xx/bcm2712 | 1 slot, `auto` | Kit. GPIO is behind the RP1 — see `PARKEZE_GPIOCHIP`. |
| `rak7268c` | ramips/mt76x8 | 1 slot, fixed SPI | **Unverified.** 8 channels. |
| `rak7268cv2` | ramips/mt76x8 | 1 slot, fixed SPI | Harvested. ImageBuilder from parkeze/openwrt-devices. 8 channels. |
| `rak7289cv2` | ramips/mt76x8 | 2 slots, fixed SPI | **Unverified.** 16 channels. |

The Pi boards share `boards/common/raspberrypi.conf` and the RAK boards share
`boards/common/rakwireless.conf`, so each individual board file is a dozen
lines of genuine difference.

`rak7268cv2` was harvested from a stock unit. Its OpenWrt device support
lives in the public [parkeze/openwrt-devices](https://github.com/parkeze/openwrt-devices)
repo, whose releases publish an ImageBuilder with it added; the board points
`OPENWRT_IMAGEBUILDER_URL` at one, and `build.sh` downloads and verifies it
like a stock one. The other two RAK
boards are still written from published specifications; see
[`../devices/README.md`](../devices/README.md) for taking one through the same
process.

## A Compute Module carrier

When we build our own board around a CM, it does **not** source
`raspberrypi.conf`. At that point the hardware is ours and known, so it
declares its slots explicitly and sets `PARKEZE_CONCENTRATOR_CONFIGURABLE="0"`
— the same shape as the RAK boards. `raspberrypi.conf` is specifically the
"somebody plugged an unknown HAT into this" case.
