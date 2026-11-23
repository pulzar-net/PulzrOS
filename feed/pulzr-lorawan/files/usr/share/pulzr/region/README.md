# Region plans

One directory per regulatory region:

| File | What it is |
|---|---|
| `region.toml` | concentratord's region file: beacon and regional TX limits |
| `channels.toml` | concentratord's channel file: the sub-band this fleet listens on |
| `region.conf` | ours, sourced by `pulzr-lora-config` |

`region.toml` and `channels.toml` are ChirpStack Concentratord's own examples
(MIT), copied unmodified, so they stay diffable against upstream. `US915` uses
`channels_us915_1.toml`: channels 8-15 plus 65, which is what production
ChirpStack's `us915_0` region is configured for.

`region.conf` carries what the gateway needs beyond the radio:

- `CONCENTRATORD_REGION` concentratord's region name.
- `TOPIC_PREFIX` the ChirpStack region id this gateway publishes under. It
  has to match the `topic_prefix` of the region enabled server-side, or uplinks
  arrive at the broker and go nowhere.
- `LBT_REQUIRED` whether listen-before-talk is mandatory. A region that
  requires it on a part that cannot do it makes `pulzr-lora-config` refuse to
  render, because transmitting without LBT where it is required is a regulatory
  problem rather than a performance one.

## Adding a region

Copy concentratord's `region_<region>.toml` and the `channels_<plan>.toml` for
the sub-band the server-side region uses, and write `region.conf`. The console's
region menu is a fixed list in `lorawan.uc`; the directory is what gets used.
