# Concentrator profiles

One JSON file per supported part. The filename minus `.json` is the model id
that `parkeze-concentrator-detect` writes into UCI, and the id the console
shows in the hardware menu.

A profile describes **the part**, including how to reset it on the bus it
answers on — that used to live in `/etc/parkeze/board.conf` instead, one value
per board, which is wrong on a Pi: any of several HATs with different reset
pins can be fitted to the same board, and a value that describes the board
cannot also describe whichever of them somebody bolted on. Regional facts
(which channels, which datarates) still come from the region directory under
`region/` — that split is real, a Pi 3 + WM1302 in the US and a RAK7268 in the
EU do share every line of code for it.

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
- `resetGpio`, `powerGpio`  BCM numbers, `spi` parts only. What
                 `parkeze-concentrator-detect` pulses to bring the part out of
                 reset and read its version register — the only way to tell an
                 SX130x is there at all, since SPI has no discovery.
- `sx1261ResetGpio`, `ad5338rResetGpio`  BCM numbers, optional, `spi` parts
                 only. The two extra lines a CoreCell-style module's reference
                 design also drives (Semtech's `reset_lgw.sh`, which
                 Waveshare's SX1302 HAT follows) — absent on the RAK/Seeed
                 convention, which has neither.

## Telling two SX1302 HATs apart, which the bus alone cannot do

`sx1302_spi` is an SX1302 behind SPI — a RAK2287, a RAK5146, a WM1302 — and
reading its version register cannot distinguish any of those from a Waveshare
SX1302 HAT: they are the same chip, answering the same way, once reset. What
*is* different is the reset line each one is wired to, and that is the actual
discriminator: `parkeze-concentrator-detect` probes with one profile's pins at
a time, and a HAT only answers the profile whose pins match how it is wired.

A Pi tries the board's default profile — the most common fitment,
`PARKEZE_CONCENTRATOR_DEFAULT_PROFILE` in board.conf — and reports absent if
that is not what is actually fitted. It does not go on to try every other
profile's pins in turn: a HAT that shares no lines with the wrong guess is
unaffected either way, but one that reuses a pin for something else — a GNSS
standby line, on the Waveshare HAT — is not something to pulse on a guess. Pick
the right one from the console's hardware menu instead, which re-probes with
that profile's own pins:

    uci set parkeze.slot0.override='waveshare_sx1302_lorawan_gateway_hat'
    uci commit parkeze
    /etc/init.d/parkeze-packet-forwarder restart

Adding support for a HAT this catalog does not know is a new profile file
with its pins, model and known_as — no script change, and it appears in the
console's menu the moment the package ships it. The same file is also the
authority "the model" the paragraph below is about.

## The vendor model, and why the profile's is only a default

`model` in a profile is what gets written into concentratord's config, and
concentratord uses it to pick a **radio calibration**: the RSSI offset it
reports signal strength against, and the transmit gain table it keys power
against. Get it wrong and the gateway still runs — it receives, it forwards,
the LNS shows it online — while reporting signal strengths that are off and
transmitting at powers that are not the ones asked for. Picking the right
profile in the hardware menu sets this too, for the same reason it sets the
reset pins: `active`, not `detected`, is what `parkeze-lora-config` reads.

`PARKEZE_CONCENTRATOR_MODEL` in board.conf sets a model directly, for a board
where the part is soldered down and there is nothing to guess.

The names are concentratord's, not ours — `rak_2287`, `rak_5146`,
`seeed_wm1302`, `waveshare_sx1302_lorawan_gateway_hat`, the `semtech_*` and
`multitech_*` families. An unknown name makes concentratord exit at startup
rather than run miscalibrated, which is the right way round.

A GNSS on the UART is picked up automatically: once `parkeze-gps-detect` finds
a receiver, the generator adds the `GNSS` model flag and the device path, and
concentratord takes the port over for PPS and time. That detection needs
`stty`, which is not in the image's BusyBox — hence the `coreutils-stty`
dependency.

