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
- which features it has (`PULZR_FEATURES`, see [features.md](features.md))
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

2. Add board-specific kernel modules to `PACKAGES_BOARD`, and set
   `PULZR_FEATURES` to what the board is for. A feature's packages come with
   the word; `build.sh` refuses a word the board cannot back
   ([features.md](features.md)).

3. Declare the concentrator slots. See `docs/concentrators.md` for the model:

   - **Fixed hardware** (a RAK unit, a CM carrier): list each slot explicitly,
     e.g. `PULZR_CONCENTRATOR_SLOTS="spi:/dev/spidev0.0:17"`, and set
     `PULZR_CONCENTRATOR_CONFIGURABLE="0"`.
   - **A kit** (a Pi): `PULZR_CONCENTRATOR_SLOTS="auto"`. Every bus is
     probed and everything stays operator-editable.

4. Map the LEDs and the button. `PULZR_LED_*` take names from
   `/sys/class/leds`, and the only reliable way to fill them in is to look on
   the running board — `pulzr-led --list` prints both the map and what the
   kernel actually exposes, and `pulzr-led --test` walks them so a wrong name
   is obvious in ten seconds. A board with fewer LEDs simply leaves names
   unset; `pulzr-io-daemon` folds their state into the ones that exist rather
   than pretending the board has more lights than it does.

   `PULZR_LEDS` lists the panel itself, one `<sysfs name> <colour> <role>
   <label>` line per light the SoC drives, from the board's device tree
   (`boards/common/board.conf` has the words each column takes). The
   console's Panel page shows exactly these, with what each is doing now; a
   board that leaves it empty gets `/sys/class/leds` listed instead.

5. Optionally add `boards/<id>/files/` for literal files to overlay. These win
   over `boards/common/files/`.

6. `./build.sh <id>`.

## Adding a concentrator, not a board

Drop a JSON file into
`feed/pulzr-concentrator/files/usr/share/pulzr/concentrator/`. That is the
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

Every board, its features, radio slots, panel lights and status, is on its
[Hardware](/hardware/) page, generated from its `board.conf` when the docs
site is built (`scripts/board-facts.sh`), so there is no table here to fall
behind.

The RAK V2, RAK7391, RAK7266/7267, SenseCAP M2 and LPS8N boards come from what
ChirpStack Gateway OS supports. Their radio facts (part, bus, reset and power
lines) are read from ChirpStack's OpenWrt feed, which is MIT; Gateway OS's own
repository carries no license, so its device patches are a reference to read
against when writing a board's device support, never files to copy. Each
board's header says what is known and what has to come off a unit.

The Pi boards share `boards/common/raspberrypi.conf` and the RAK boards share
`boards/common/rakwireless.conf`, so each individual board file is a dozen
lines of genuine difference.

`rak7268cv2` was harvested from a stock unit. Its OpenWrt device support
(a DTS and a patch against OpenWrt, the hardware record in its README) is
`boards/rak7268cv2/openwrt/`; `scripts/device-imagebuilder.sh` builds an
ImageBuilder from it, which CI does once per change to those files, and the
board names it in `OPENWRT_DEVICE_SUPPORT`. Every board OpenWrt does not
support yet works the same way, until OpenWrt carries it and the folder goes.

`rak7289cv2` shares the RAK636 board, so its device support was written from
that same shipping firmware rather than a fresh harvest — `boards/rak7289cv2/openwrt/`.
Its two radios are RAK5146 (SX1303) cards on **USB** (`/dev/lora0` and
`/dev/lora1`, linked by hub port to whichever ttyACM each card gets), not SPI — the one hardware difference from the Lite. A bench
run of the full `24.10.0-1` PulzarOS image confirmed it boots as
`rakwireless,rak7289cv2` with concentratord driving the SX1303 on
`/dev/ttyACM0` (8 channels, gateway ID read off the hardware) and GNSS on
`/dev/ttyS1`; the absent second card was reported as the partial state. It is
`supported` on that basis — the two-slot structure is ready — with only the
silkscreen LoRa1/LoRa2 order left to confirm on a Pro with both cards.
`gl-sft1200` is the GL.iNet Opal, the first board that is a router rather
than a LoRa gateway: one WAN port and two LAN ports on a MaxLinear GSW150
switch, and Siflower's two radios on their GPLv2 driver (`kmod-siwifi`). Its target is source-only in 25.12 and has no GSW150
driver on 6.12, so `boards/gl-sft1200/openwrt/`, with `scripts/device-imagebuilder-graft.sh`,
builds the 25.12.6 tree with siflower's 6.18 kernel grafted in, and an
ImageBuilder that carries the kernel, every kmod and the target's own
packages while installing the release's userland. `check-deps.sh` lists what
that ImageBuilder has to supply. Its README is the board's hardware record and
the harvest and recovery procedure. The harvested unit has booted PulzarOS
0.3.5 on its 25.12.6-2: all three ports at 1 Gbps, DHCP and DNS on devlan,
the console on the WAN port and the TUI on serial, warm and cold. Adoption,
cellular and failover have not been seen on it; it had no uplink and no
modem.

`rak7268c` is still written from published specifications; see the template's
README for taking a board through the same process.

## Moving to a new OpenWrt release

`OPENWRT_VERSION` in `boards/common/board.conf` is the whole fleet's release,
and every board moves with it: the feed's ucode is compiled for the release's
exact ucode (`scripts/host-ucode.sh`), so two releases at once would mean two
feeds.

1. Change `OPENWRT_VERSION` and run `scripts/check-deps.sh`. It reads the
   release's `index.json` files and names every package that is gone or
   renamed. Libraries are listed there without their ABI suffix (`libstdcpp`,
   not `libstdcpp6`), and that is the name to depend on.
2. Nothing per board, unless a board's `openwrt/openwrt.patch` no longer
   applies to the new release tag: CI's device-support job says so, and the
   fix is rebasing that patch (a patch touches four files, so this is a few
   minutes of context fixing).
3. `./build.sh --all`, and boot one image of each target before releasing.

24.10.0 to 25.12.6 took this for the RAK repos: `uboot-envtools` moved from
`package/boot/uboot-envtools` to `package/boot/uboot-tools/uboot-envtools`, and
new boards in the `uboot-envtools` and `02_network` lists moved the context
lines. The DTS and the image recipe applied unchanged.

## USB cellular

A board with a free USB host port adds `PACKAGES_USB_CELLULAR` to
`PACKAGES_BOARD`, for a modem, dongle or phone plugged into it; see
[backhaul.md](backhaul.md), "Cellular adapters", for what works.

| Board | USB cellular |
|---|---|
| `rpi3`, `rpi4`, `rpi5` | yes |
| `gl-sft1200` | yes; the kmods come from openwrt-gl-sft1200's ImageBuilder, which builds every kmod |
| RAK | no: the one USB port is the soldered QMI modem's |

## Where the terminal UI runs

Every board has the terminal UI on its serial console. Two features add
somewhere else for it to run, and a board takes one by adding its package
group to `PACKAGES_BOARD` and setting its variables — see the Display and USB
device port sections of `boards/common/board.conf`. A board without the
hardware leaves them alone, and nothing for them is in its image.

| Board | Serial console | Display | USB device port |
|---|---|---|---|
| `rpi3` | 115200 | HDMI | no — its USB sockets are behind the LAN hub |
| `rpi4` | 115200 | HDMI | USB-C, `dwc2` |
| `rpi5` | 115200 | HDMI | USB-C, `dwc2` |
| RAK | 57600, on the USB-C socket | no | no — that socket is a CH340 on the UART |
| `gl-sft1200` | 115200, inside the case | no | no |

A board's console baud rate is its own business; the TUI asks the terminal for
its size rather than assume one.

## A Compute Module carrier

When we build our own board around a CM, it does **not** source
`raspberrypi.conf`. At that point the hardware is ours and known, so it
declares its slots explicitly and sets `PULZR_CONCENTRATOR_CONFIGURABLE="0"`
— the same shape as the RAK boards. `raspberrypi.conf` is specifically the
"somebody plugged an unknown HAT into this" case.
