# Concentrator profiles

One JSON file per supported part. The filename minus `.json` is the model id
that `parkeze-concentrator-detect` writes into UCI, and the id the console
shows in the hardware menu.

A profile describes **the part**, not the board and not the region. Board facts
(which GPIO the reset line is on, which spidev node) come from
`/etc/parkeze/board.conf`; regional facts (which channels, which datarates)
come from the region plan under `region/`. Keeping the three apart is what lets
a Pi 3 + WM1302 in the US and a RAK7268 in the EU share every line of code.

Fields:

- `name`         human label for the console.
- `chip`         `sx1301` | `sx1302` | `sx1303`.
- `interface`    `spi` | `usb` | `uart`.
- `forwarder`    which packet forwarder binary drives it. The SX1301 parts need
                 the legacy `lora_pkt_fwd`; SX1302/3 use `sx1302_hal`.
- `antennas`     number of RF chains, which the region plan is spread across.
- `channels`     how many LoRa channels this part carries. Eight for every
                 SX130x we support — a 16-channel gateway is two of these in
                 two slots, not one part with sixteen. See
                 `docs/concentrators.md`.
- `lbt`          whether the part supports listen-before-talk in hardware.
                 Required in some regions and not others; a region that
                 mandates it on a part that lacks it is a configuration error
                 the console surfaces rather than a silent non-compliance.
