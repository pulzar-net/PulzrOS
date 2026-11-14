# Concentrators and channel counts

## Slots

A **slot** is one SX130x and the eight channels it carries.

- An 8-channel gateway (Pi + one HAT, RAK7268C) has one slot.
- A 16-channel gateway (RAK7289CV2) has two.

Sixteen channels is not one concentrator with twice the channels — it is two
eight-channel parts on separate SPI buses. Concentratord drives one part per
process, so a two-slot board runs two of it.

Modeling every board as a list of slots, rather than treating one concentrator
as the general case and 16-channel as a special case, is what keeps the
RAK7289CV2 from being a fork. `pulzr-concentrator-detect` and the packet
forwarder init both just loop.

## Declaring slots

In `boards/<id>/board.conf`:

```sh
# A kit — probe every bus.
PULZR_CONCENTRATOR_SLOTS="auto"

# One fixed concentrator.
PULZR_CONCENTRATOR_SLOTS="spi:/dev/spidev0.0:17"

# Two.
PULZR_CONCENTRATOR_SLOTS="spi:/dev/spidev0.0:17 spi:/dev/spidev1.0:18"
```

Syntax is `<bus>:<device>:<reset-gpio>[:<power-gpio>]`, or `auto`.

## Kit versus product

| | Kit (a Pi) | Product (a RAK unit) |
|---|---|---|
| Slots | `auto` | declared explicitly |
| Probed at boot | yes, every bus | no: the board declares the part, and a dead one shows as concentratord not running |
| Operator-editable in the console | yes — bus, device node, reset GPIO, part | no |

`PULZR_CONCENTRATOR_CONFIGURABLE` controls the last row, and the console
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

## What runs on the gateway

The gateway half of ChirpStack, and nothing server-side. Per slot:

| Process | Does |
|---|---|
| `chirpstack-concentratord-<chip>` | drives the SX130x, resets it on start, publishes frames on a local socket |
| `chirpstack-mqtt-forwarder` | carries those frames to the cloud network server over MQTT/TLS |

`pulzr-lora-config` renders both configs from the profile, the region
directory and UCI. The forwarder authenticates with the credentials adoption
issued (`pulzr.mqtt.*`) and publishes under the region's `TOPIC_PREFIX`,
which has to match the `topic_prefix` of the region enabled in ChirpStack.
Until a gateway is adopted it has no credentials: the radio still runs, and
the uplinks go nowhere.

The binaries are ChirpStack's own builds, pinned by checksum in
`feed/chirpstack-gateway/fetch`. The MIPS ones come from ChirpStack Gateway OS,
because they carry the half-duplex SPI patch the MT7628 needs and ChirpStack
publishes no standalone MIPS build.

## Two concentrators

Slot 0 uses the gateway's EUI. A second slot runs its own concentratord and
forwarder under its chip's own EUI, so ChirpStack sees a 16-channel unit as two
8-channel gateways. That is honest about what it is; presenting it as one
16-channel gateway needs aggregation that does not exist yet, and is the next
thing to do before the RAK7289CV2 ships.

## Adding a part

Drop a JSON file into
`feed/pulzr-concentrator/files/usr/share/pulzr/concentrator/`. That is the
whole of it — the console's hardware menu reads that directory, so a new part
appears as a selectable option with no UI change and no SPA rebuild.

A profile describes **the part**, not the board and not the region. Board facts
live in `board.conf`, regional facts in `region/<REGION>/`. Keeping the
three apart is what lets a Pi 3 + WM1302 in the US and a RAK7289CV2 in the EU
share every line of code.

## GNSS

A gateway reports its position to the network server, and one with a real
receiver also gives concentratord GPS time and PPS — which is what fine
timestamping needs.

### Where the receiver is

| Build | Where GNSS lives |
|---|---|
| Pi + SPI HAT (RAK2287/5146 SPI, WM1302) | the HAT's GNSS module, on the Pi's own UART |
| Pi + USB concentrator | a second tty on the same stick |
| RAK WisGate | integrated, declared by the board |

`pulzr-gps-detect` probes UART first, then USB, listening for NMEA. It
detects the *receiver*, not a fix — a gateway being configured in a rack before
it goes on a roof should still show its GPS as present.

### The one configuration that does not work

A UART **concentrator** and a UART **GNSS** cannot share the Pi's one serial
port. Detection refuses to claim a port a concentrator already holds, rather
than letting the two fight and producing a gateway where each subsystem works
until the other starts. In that build the GPS goes on USB.

### Who owns the serial port

We give concentratord the GNSS tty itself in `gnss_dev_path`, and it holds
the port — only the process holding it has GPS time. It sends its position to
the network server rather than logging it, so while it runs the gateway cannot
read the receiver locally, and `pulzr-gps status` says so rather than
reporting a stale fix. Stopping the LoRa service frees the port for a direct
read.

That is our choice, not a limit of concentratord: it also takes
`gnss_dev_path="gpsd://localhost:2947"` (since 2022), and ChirpStack Gateway
OS runs gpsd that way on the RAK7289v2, so the receiver could be shared. PPS
still has to be wired to the SX130x itself; gpsd carries the NMEA, not the
pulse.

On a two-slot gateway only slot 0 is given the receiver: one physical gateway
has one position.

### Live fix versus reported position

These are different and the console shows both.

A gateway announces its **reference** position — captured once at install with
`pulzr-gps sync`, or set manually — whether or not the receiver has a fix on
any given boot. That is deliberate: gateways do not move, and one whose antenna
is under snow should keep reporting where it is.

The failure it hides is a gateway announcing a position while blind. A unit
whose antenna was knocked loose keeps reporting the old coordinates quite
happily, and the only way to notice is to see the live fix missing beside them
— which is exactly what the GNSS card puts side by side.

With no receiver at all, concentratord gets the reference coordinates as its
static `[gateway.location]`. With one, it gets `gnss_dev_path` and real time.
