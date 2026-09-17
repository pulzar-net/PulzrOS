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
