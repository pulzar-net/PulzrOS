# Concentrator profiles

One JSON file per supported part. The filename minus `.json` is the model id
that `parkeze-concentrator-detect` writes into UCI, and the id the console
shows in the hardware menu.

A profile describes **the part**, not the board and not the region. Board facts
(which GPIO the reset line is on, which spidev node) come from
`/etc/parkeze/board.conf`; regional facts (which channels, which datarates)
come from the region directory under `region/`. Keeping the three apart is what lets
a Pi 3 + WM1302 in the US and a RAK7268 in the EU share every line of code.

Fields:

- `name`         human label for the console.
- `chip`         `sx1301` | `sx1302` | `sx1303`.
- `interface`    `spi` | `usb` | `uart`.
- `concentratord` which ChirpStack Concentratord build drives it:
                 `sx1301` or `sx1302` (the SX1303 is driven by the SX1302
                 build). `null` for a part concentratord cannot drive — today
                 the UART builds — which `parkeze-lora-config` refuses to
                 render rather than start something that cannot work.
- `model`        concentratord's model for the part, which selects its TX gain
                 table and RSSI offsets. A default: a board that knows its
                 module sets `PARKEZE_CONCENTRATOR_MODEL`, and `parkeze.slotN.model`
                 overrides both.
- `antennas`     number of RF chains, which the region plan is spread across.
- `channels`     how many LoRa channels this part carries. Eight for every
                 SX130x we support — a 16-channel gateway is two of these in
                 two slots, not one part with sixteen. See
                 `docs/concentrators.md`.
- `lbt`          whether the part supports listen-before-talk in hardware.
                 Required in some regions and not others; a region that
                 mandates it on a part that lacks it is a configuration error
                 the console surfaces rather than a silent non-compliance.

## The vendor model, and why the profile's is only a default

`model` in a profile is what gets written into concentratord's config, and
concentratord uses it to pick a **radio calibration**: the RSSI offset it
reports signal strength against, and the transmit gain table it keys power
against. Get it wrong and the gateway still runs — it receives, it forwards,
the LNS shows it online — while reporting signal strengths that are off and
transmitting at powers that are not the ones asked for.

The profile cannot know which board it is on. `sx1302_spi` is an SX1302 behind
SPI, which is a RAK2287, a RAK5146, a WM1302 and a Waveshare SX1302 HAT alike,
and none of them can be told apart over the bus. So the profile carries the
most common one as a default and the unit names its own:

    uci set parkeze.slot0.model='waveshare_sx1302_lorawan_gateway_hat'
    uci commit parkeze
    /etc/init.d/parkeze-packet-forwarder restart

`PARKEZE_CONCENTRATOR_MODEL` in board.conf does the same for a board where the
part is soldered down and there is nothing to guess.

The names are concentratord's, not ours — `rak_2287`, `rak_5146`,
`seeed_wm1302`, `waveshare_sx1302_lorawan_gateway_hat`, the `semtech_*` and
`multitech_*` families. An unknown name makes concentratord exit at startup
rather than run miscalibrated, which is the right way round.

A GNSS on the UART is picked up automatically: once `parkeze-gps-detect` finds
a receiver, the generator adds the `GNSS` model flag and the device path, and
concentratord takes the port over for PPS and time. That detection needs
`stty`, which is not in the image's BusyBox — hence the `coreutils-stty`
dependency.

