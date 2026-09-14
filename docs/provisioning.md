# One-touch provisioning

Installing a gateway is: power it on, scan the code, pick the site. Nobody
types a credential into the device and nobody goes back to it.

## The happy path

```
  gateway                    installer's phone              parkeze.net
  ───────                    ─────────────────              ───────────
  first boot
   └ mint claim identity
       claim_id   (public, goes in the QR)
       secret     (private, never leaves the device)
       commitment = sha256(secret)

  register  ──────────────────────────────────────────────▶ pending claim
  show QR   ─────────▶ scan
                       └ open /adopt#<claim_id> ──────────▶ sign in
                                                            pick organisation
                                                            ▼
                                                            adopted
  poll (with secret) ────────────────────────────────────▶ verify commitment
       ◀──────────────────────────────────── bundle: tailnet key, MQTT, anchor
   └ adopt itself, disable local login, join the tailnet
```

Steps 1–3 take about fifteen seconds. The gateway polls every 5s for the first
two minutes, so the console turns green while the installer is still holding
the phone.

## The two secrets

| | Where it lives | What knowing it gets you |
|---|---|---|
| `claim_id` | in the QR, on the screen, in the SSH banner | the ability to *claim* the gateway — which needs a Parkeze login and is audited |
| `secret` | only on the gateway | the ability to *be* the gateway and collect its credentials |

This split is the whole security argument. A QR on a screen in a rack is
visible to anyone walking past. Seeing it lets them add the gateway to an
organisation they can already administer — which is not an attack — but not
fetch its tailnet key, because that needs the preimage of the commitment and
the commitment is all parkeze.net ever stores.

## When the gateway has no internet

Common: a basement, a customer network that will not route yet, a unit
configured on a bench before it is installed.

The QR carries the gateway's identity inline instead of just a claim id:

```
https://parkeze.net/adopt#o1.<claim_id>.<eui>.<commitment[:24]>.<board>
```

parkeze.net builds the pending claim from the scan alone. From there:

- **If the gateway later gets an uplink**, it polls, presents the full secret,
  the stored 24-character prefix is checked and upgraded to the full
  commitment, and adoption finishes on its own. Nothing else is needed.

- **If it never will**, parkeze.net produces a *signed adoption bundle* the
  installer pastes into the gateway's own console. The gateway verifies it
  against the fleet public key baked into the image at build time.

That baked-in key is what makes offline adoption safe rather than just
possible. Without a trust anchor on an un-adopted gateway, any bundle a
stranger pasted in would be as good as ours — meaning anyone on the gateway's
LAN could adopt it onto their own tailnet. See `install_fleet_key` in
`build.sh`; an image built without it warns loudly and can only be adopted
online.

## Where the code appears

- **The web console.** An unadopted gateway shows nothing *but* the onboarding
  screen — no login form, because there is nothing yet to protect and a
  password prompt in front of a factory-fresh device is the thing that makes
  provisioning feel like work.
- **The SSH login banner.** `/etc/profile.d/99-parkeze-claim.sh` renders the QR
  as ANSI half-blocks, which fits an 80×24 serial console. It prints nothing
  once the gateway is adopted.
- **An SPI/I²C OLED**, eventually. `parkeze-claim qr` already emits the payload
  on its own, so a display driver is a consumer of that and needs no changes
  here.

## Why the provisioning endpoints are unauthenticated

Three routes answer without a session, and each carries its reasoning at the
route:

| Route | What stands in for auth |
|---|---|
| `POST /claim/register` | nothing, and it grants nothing — it creates a pending row and echoes back the id the caller already sent |
| `POST /claim/poll` | the claim secret, whose hash was registered above |
| `POST /adopt` | a single-use adoption code minted by a net-admin |

On the device side, `/api/claim/*` is open for the same reason — a gateway out
of the box has a password nobody has read off the serial console yet — and
**stops answering the moment the gateway is adopted**. That guard is in
`api/index.uc`, keyed on `PROVISIONING_ONLY`.

## Claim lifetime

- Claims expire after 90 days. A gateway that sat in a warehouse for a year
  should not still be adoptable by whoever finds the box.
- One live unadopted claim per EUI, enforced by a partial unique index. A
  reflashed gateway registers a new claim and the old one is deleted — its
  secret went with the overlay, and leaving it would be a second live door.
- The poll backs off: 5s for two minutes, 30s to fifteen, 5m to an hour, then
  hourly. The first window is sized for a human standing there; the last is
  sized for a SIM's data allowance.
