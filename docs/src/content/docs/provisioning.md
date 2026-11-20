---
title: "One-touch provisioning"
description: "Installing a gateway is: power it on, sign in to its console with the password on its label, scan the code, pick the site."
---

Installing a gateway is: power it on, sign in to its console with the
password on its label, scan the code, pick the site.

## The happy path

```
  gateway                    installer's phone              Pulzar Cloud
  ───────                    ─────────────────              ───────────
  first boot
   └ mint claim identity
       claim_id   (public, goes in the QR)
       secret     (private, never leaves the device)
       commitment = sha256(secret)

  register  ──────────────────────────────────────────────▶ pending claim
  show QR   ─────────▶ scan
                       └ open /adopt#<claim_id> ──────────▶ sign in
                                                            pick organization
                                                            ▼
                                                            adopted
  poll (with secret) ────────────────────────────────────▶ verify commitment
       ◀──────────────────────────────────── bundle: MQTT, anchor
   └ adopt itself, disable local login, enroll its WireGuard key
```

Steps 1–3 take about fifteen seconds. The gateway polls every 5s for the first
two minutes, so the console turns green while the installer is still holding
the phone.

## The two secrets

| | Where it lives | What knowing it gets you |
|---|---|---|
| `claim_id` | in the QR, behind the console's sign-in and on the gateway's own ports | the ability to *claim* the gateway into any organization one runs |
| `secret` | only on the gateway | the ability to *be* the gateway and collect its credentials |

Whoever holds the claim code can adopt the gateway, which makes it a key, so
it is shown only to somebody who has shown they hold the gateway: a session
(the label's password, on an unadopted gateway) or the serial, HDMI and USB
consoles. It used to be open to anybody on the site's network, and a new
gateway on a shared network was anybody's to take. The secret is what keeps
the claim from being enough to *be* the gateway: its broker credentials and
tunnel key both need the preimage of the commitment, and the commitment is
all Pulzar Cloud ever stores.

A gateway's EUI is random (`10-pulzr-identity`), not its MAC's: Pulzar Cloud
takes a claim for any EUI from anyone, and an EUI read off a label or a
network could have a stranger's claim adopted for it first. One from before
0.4 keeps the EUI it has.

## When the gateway has no internet

Common: a basement, a customer network that will not route yet, a unit
configured on a bench before it is installed.

The QR carries the gateway's identity inline instead of just a claim id:

```
https://app.pulzr.net/adopt#o1.<claim_id>.<eui>.<commitment[:24]>.<board>
```

Pulzar Cloud builds the pending claim from the scan alone. From there:

- **If the gateway later gets an uplink**, it polls, presents the full secret,
  the stored 24-character prefix is checked and upgraded to the full
  commitment, and adoption finishes on its own. Nothing else is needed.

- **If it never will**, Pulzar Cloud produces a *signed adoption bundle* the
  installer pastes into the gateway's own console. The gateway verifies it
  against the fleet public key baked into the image at build time.

That baked-in key is what makes offline adoption safe rather than just
possible. Without a trust anchor on an un-adopted gateway, any bundle a
stranger pasted in would be as good as ours — meaning anyone on the gateway's
LAN could adopt it into their own fleet. See `install_fleet_key` in
`build.sh`; an image built without it warns loudly and can only be adopted
online.

## When the claim is revoked

Pulzar Cloud revokes every claim a gateway was adopted with when it is
released, or adopted again by code. A transfer to another organization does
not: the claim is the gateway's identity, and the previous owner has no root
to have read the secret with. From then on its reports and tunnel enrolments
are answered 404 `No such gateway.`.

The gateway stays adopted. It keeps forwarding and keeps its tunnel, and after
two such answers a minute apart it mints a second claim beside the first and
registers it. That code is shown where the first one was — a banner after
sign-in, the physical consoles, the status LED at 1Hz — and polled from the report loop: every 30s for fifteen minutes, 5m to an
hour, then hourly, counted from when it was minted. Only the organization that
owns the gateway can adopt it. When it does, the new claim replaces the old
one, the bundle is installed as at first adoption (a new broker password), and
the gateway enrols again, which moves the tunnel to the new owner's hub.

One waiting claim at a time. It is registered once; if Pulzar Cloud later says
it has never heard of it, it is registered again under the same code, and if
Pulzar Cloud refuses it outright, a new one replaces it. A report that is
accepted again drops it.

`pulzr-claim reclaiming` says whether one is waiting; `pulzr-claim status`
shows it, with `state` `reclaiming`.

## Where the code appears

- **The web console**, after sign-in: on an unadopted gateway, the label's
  password. The onboarding screen is what opens.
- **The terminal console**: before sign-in on the serial, HDMI and USB ports,
  which are physical access; after it over `ssh pulzr@`.
- **A root shell's login banner.** `/etc/profile.d/99-pulzr-claim.sh` renders
  the QR as ANSI half-blocks. It prints nothing once the gateway is adopted.
- **An SPI/I²C OLED**, eventually. `pulzr-claim qr` already emits the payload
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

On the device side, only `POST /api/claim/apply` is open: an offline bundle is
Pulzar Cloud's signature over this gateway's EUI, which nobody gets without
having adopted it. The rest of `/api/claim/*` needs a session, and every claim
route **stops answering the moment the gateway is adopted** (`PROVISIONING_ONLY`
in `api/index.uc`).

## Claim lifetime

- Claims expire after 90 days. A gateway that sat in a warehouse for a year
  should not still be adoptable by whoever finds the box.
- One live unadopted claim per EUI, enforced by a partial unique index. A
  reflashed gateway registers a new claim and the old one is deleted — its
  secret went with the overlay, and leaving it would be a second live door.
- The poll backs off: 5s for two minutes, 30s to fifteen, 5m to an hour, then
  hourly. The first window is sized for a human standing there; the last is
  sized for a SIM's data allowance, so it applies only on cellular: with the
  wired port or a WiFi uplink up, the poll stays at 30s for as long as the
  gateway is unadopted, and an adoption is picked up within half a minute
  however long after power-on it happens.
