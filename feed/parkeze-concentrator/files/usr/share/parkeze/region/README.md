# Region plans

One file per regulatory region, in Semtech `global_conf.json` form.

A plan describes **the region**, not the part and not the board.
`parkeze-lora-config` copies the plan through almost verbatim and substitutes
only the three fields that depend on this gateway — `com_type`, `com_path` and
`gateway_ID` — so these files stay readable and diffable against Semtech's
published reference plans.

Two extra keys are ours, outside Semtech's schema and ignored by the forwarder:

- `parkeze_region`  the region id, so a plan can be identified from its content.
- `lbt_required`    whether listen-before-talk is mandatory here. A region that
                    requires it on a part that cannot do it makes
                    `parkeze-lora-config` refuse to render, because transmitting
                    without LBT where it is required is a regulatory problem
                    rather than a performance one.

## Adding a region

Start from Semtech's `sx1302_hal` reference config for the region, add the two
keys above, and drop it in. Nothing else changes: the console's region menu is
a fixed list in `lorawan.uc` (regions are not something a site invents), but
the plan file is what actually gets used.

Only `US915` ships fully populated today. The rest are the immediate next
thing to add and must each be checked against the current regional parameters
before they go near a radio.
