# Concentrators and channel counts

## Slots

A **slot** is one SX130x and the eight channels it carries.

- An 8-channel gateway (Pi + one HAT, RAK7268C) has one slot.
- A 16-channel gateway (RAK7289CV2) has two.

Sixteen channels is not one concentrator with twice the channels — it is two
eight-channel parts on separate SPI buses. Semtech's HAL drives one part per
process, so a two-slot board runs two packet forwarders.

Modelling every board as a list of slots, rather than treating one concentrator
as the general case and 16-channel as a special case, is what keeps the
RAK7289CV2 from being a fork. `parkeze-concentrator-detect` and the packet
forwarder init both just loop.

## Declaring slots

In `boards/<id>/board.conf`:

```sh
# A kit — probe every bus.
PARKEZE_CONCENTRATOR_SLOTS="auto"

# One fixed concentrator.
PARKEZE_CONCENTRATOR_SLOTS="spi:/dev/spidev0.0:17"

# Two.
PARKEZE_CONCENTRATOR_SLOTS="spi:/dev/spidev0.0:17 spi:/dev/spidev1.0:18"
```

Syntax is `<bus>:<device>:<reset-gpio>[:<power-gpio>]`, or `auto`.

## Kit versus product

| | Kit (a Pi) | Product (a RAK unit) |
|---|---|---|
| Slots | `auto` | declared explicitly |
| Probed at boot | yes, every bus | the chip is read, but the bus is not guessed |
| Operator-editable in the console | yes — bus, device node, reset GPIO, part | no |

`PARKEZE_CONCENTRATOR_CONFIGURABLE` controls the last row, and the console
reads it from the device rather than deciding for itself.

The reasoning: on a Pi, what is attached genuinely varies and changes when
somebody swaps a HAT, so a rebuild to correct a wrong guess would be absurd. On
a RAK unit the hardware is soldered down, so an editable bus field is only ever
a way to break a working gateway.

**No bus is preferred on a Pi.** SPI, USB and UART are all normal. The probe
order is cheapest-first — it is about how long detection takes, not about which
hardware we expect — and an operator override always wins.

## Partial detection

A two-slot gateway with one working concentrator is its own state, `partial`,
and it is loud on purpose: the gateway works, at half its channel count, and
**nothing about the uplink counts makes that obvious**. The console banners it,
the LED blinks the attention code, and the forwarder logs an error and starts
anyway — half a gateway beats none.

## Two forwarders, one gateway

With one slot, the forwarder talks straight to the ChirpStack bridge on
UDP/1700.

With more than one, both would otherwise announce themselves to the bridge with
the same EUI and whichever statistics arrived last would win. So each forwarder
gets a local port (1680 + slot index) and `gwmp-mux` fans them into one
upstream. The network server sees a single sixteen-channel gateway.

**`gwmp-mux` is not in OpenWrt's feeds and is not yet packaged here.** Until it
is, a two-slot board logs an error and only slot 0 reaches the network server —
deliberately loud, because two forwarders silently overwriting each other's
statistics gets diagnosed as "flaky coverage" for a month. Packaging it is the
next thing to do before the RAK7289CV2 ships.

The fallback, if multiplexing turns out to be the wrong call, is one EUI per
slot — two gateway records in ChirpStack for one physical unit. That works
today with no code change beyond `parkeze-lora-config`, but it makes a
16-channel gateway look like two 8-channel ones everywhere in the fleet UI,
which is why it is not the default.

## Adding a part

Drop a JSON file into
`feed/parkeze-concentrator/files/usr/share/parkeze/concentrator/`. That is the
whole of it — the console's hardware menu reads that directory, so a new part
appears as a selectable option with no UI change and no SPA rebuild.

A profile describes **the part**, not the board and not the region. Board facts
live in `board.conf`, regional facts in `region/<REGION>.json`. Keeping the
three apart is what lets a Pi 3 + WM1302 in the US and a RAK7289CV2 in the EU
share every line of code.

## GNSS

A gateway reports its position to the network server, and one with a real
receiver also gives the packet forwarder GPS time and PPS — which is what fine
timestamping needs.

### Where the receiver is

| Build | Where GNSS lives |
|---|---|
| Pi + SPI HAT (RAK2287/5146 SPI, WM1302) | the HAT's GNSS module, on the Pi's own UART |
| Pi + USB concentrator | a second tty on the same stick |
| RAK WisGate | integrated, declared by the board |

`parkeze-gps-detect` probes UART first, then USB, listening for NMEA. It
detects the *receiver*, not a fix — a gateway being configured in a rack before
it goes on a roof should still show its GPS as present.

### The one configuration that does not work

A UART **concentrator** and a UART **GNSS** cannot share the Pi's one serial
port. Detection refuses to claim a port a concentrator already holds, rather
than letting the two fight and producing a gateway where each subsystem works
until the other starts. In that build the GPS goes on USB.

### Who owns the serial port

The packet forwarder opens the GNSS tty itself when configured with
`gps_tty_path`, and does not share it. That is correct — only the process
holding the port can have PPS — but it means nothing else can read the receiver
while the forwarder runs. So position comes from two places:

- **forwarder running** — the cached position, scraped by
  `parkeze-forwarder-stats` from the forwarder's own periodic log line.
- **forwarder stopped** — a direct read.

The `source` field in `parkeze-gps status` says which happened, and the console
shows it, so nobody has to guess how fresh a coordinate is.

On a two-slot gateway only slot 0 is given the receiver: one physical gateway
has one position, and two forwarders opening the same tty means the second one
loses in a way that looks like intermittently missing GPS.

### Live fix versus reported position

These are different and the console shows both.

A gateway announces its **reference** position — captured once at install with
`parkeze-gps sync`, or set manually — whether or not the receiver has a fix on
any given boot. That is deliberate: gateways do not move, and one whose antenna
is under snow should keep reporting where it is.

The failure it hides is a gateway announcing a position while blind. A unit
whose antenna was knocked loose keeps reporting the old coordinates quite
happily, and the only way to notice is to see the live fix missing beside them
— which is exactly what the GNSS card puts side by side.

With no receiver at all, the forwarder gets `fake_gps: true` and the reference
coordinates. With one, it gets `gps_tty_path` and real time.
