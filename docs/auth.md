# Console authentication

How you get into a gateway's own web console, and why it works the way it does.

## The problem

A gateway lives on a pole or in a cabinet. It is worth stealing. And it has to
stay administrable when its backhaul is down — which is exactly when you most
need to get into it and exactly when central identity is unavailable.

Those pull in opposite directions:

- **If offline local login always works with a stored credential**, then
  whoever physically holds a stolen gateway can extract that credential from
  flash at their leisure. Flash is not a secret store. Note that physical
  presence proves nothing here: a thief has *more* physical presence than we
  do, so a reset-button or serial-console gate is not a control, it is a
  speed bump.

- **If offline login never works**, then a site with a dead SIM and a dead
  uplink is a truck roll with a laptop that cannot do anything when it arrives.

## Three states, three answers

Rather than stretch one mechanism over all of it:

### 1. Unadopted

Nobody owns this gateway yet. The console shows the **claim screen** and
nothing else — no login form, because there is nothing yet to protect and a
password prompt in front of a factory-fresh device is what makes provisioning
feel like work. See [`provisioning.md`](provisioning.md).

A local account still exists behind that, for the cases provisioning does not
cover — a bench unit, a gateway being reconfigured before it is claimed.

The password is **unique per unit**, generated on first boot from
`/dev/urandom`, and printed on the serial-console banner. It is not
`parkeze/parkeze` — which is what the previous ParkezeOS shipped on every
image, and which means one published README is root on the entire fleet.

The cleartext copy lives at `/etc/parkeze/console/initial-password`, mode 0600,
so an installer can read it off the device. The console nags on every page
until it is changed, and deletes the cleartext the moment it is.

### 2. Adopted and online

parkeze.net is the identity provider. The console accepts a signed one-time
handoff token minted by `recovery-service`, so an operator already
authenticated centrally lands signed in without a second password.

**Local password login is disabled on adoption** — `parkeze.console.local_login`
goes to `0` — not merely discouraged.

### 3. Adopted and offline

The interesting case. Local login stays refused, because the credential a thief
could extract must not be a way in. Instead: an Ed25519 challenge-response
against a key the gateway only ever holds the **public** half of.

## Offline recovery, step by step

1. The gateway prints a challenge — its EUI, a fresh 12-byte random nonce, and
   the time — as one string:

   ```
   a84041ffff1234ab.9f3c2b1a8e7d6c5b4a39281f.1789330979
   ```

2. The operator carries it to parkeze.net on a second device. A phone has
   cellular even when the gateway's uplink is dead.

3. parkeze.net checks they are a net-admin, claims the nonce in
   `gateway_recovery_events` (a unique index, so a nonce can be signed exactly
   once), writes an audit row, and has `recovery-service` sign those exact
   bytes with the fleet Ed25519 key.

4. The operator carries the base64 signature back and types or pastes it in.

5. The gateway verifies it with `openssl pkeyutl -verify -pubin -rawin` against
   `/etc/parkeze/recovery.pub`, spends the challenge, and grants a 30-minute
   session that the UI banners as a recovery session with a live countdown.

### What this buys

- The gateway stores **no secret that grants access to it**. Dump the flash of
  a stolen gateway and you get a public key, which is worth nothing.
- Every recovery is authorised and audited centrally, even though the gateway
  was never online.
- The nonce makes each signature good exactly once, for one device. A recovery
  code left in a chat window is not a standing key.

### What it costs

An operator needs a second device with connectivity. That is the trade, and it
is acceptable: the alternative is an extractable skeleton key. It is the same
trade a car key fob makes.

### The failure mode to know about

A gateway adopted **without** a recovery key installed can only be recovered by
reflashing it. Two things prevent that:

- `build.sh` bakes the fleet **public** key into the image, so a gateway has an
  anchor from first boot — this is also what makes offline adoption possible at
  all. An image built without one warns loudly.
- `parkeze-adopt` refuses to complete if neither the bundle nor the image
  supplies an anchor, and leaves local sign-in enabled rather than locking the
  gateway into a state with no way back in.

## The key itself

One Ed25519 keypair for the whole fleet.

- **Public half** — installed on every gateway at adoption, at
  `/etc/parkeze/recovery.pub`.
- **Private half** — exists only in `recovery-service`, mounted read-only from
  the secret store. Never in an environment variable in production: those show
  up in `docker inspect` and in whatever shipped your logs.

Generate it with `parkeze.net/tools/generate-recovery-key.sh`.

If the private key leaks, the security property above is gone for **every
gateway already deployed**, retroactively — not just future ones. Rotating
means re-adopting the entire fleet, because the public key is installed at
adoption. Keep the retired private key in the secret store rather than
destroying it, so gateways still holding the old public key remain recoverable
until they are re-adopted.

## Everything else about the session layer

- **Password hashing** — sha512crypt at 100k rounds via `busybox mkpasswd`.
  ucode has no KDF and `ucode-mod-digest` offers plain hashes only; libcrypt is
  already on the device and produces a standard `$6$rounds=N$salt$hash` string.
  The password goes to `mkpasswd` over a pipe, so it never touches disk and
  never appears in the process table.
- **Sessions** — 32 random bytes, stored under `/var/run` so a reboot logs
  everybody out. Looked up by `sha256(token)` so a token containing `..` cannot
  traverse the filesystem.
- **Cookies** — HttpOnly, Secure, SameSite=Strict, Path=/.
- **CSRF** — every non-GET must echo the session's CSRF token in
  `X-Parkeze-CSRF`. Belt-and-braces over SameSite, because the console is also
  reachable through the parkeze.net proxy under a different origin where
  SameSite reasoning gets subtle.
- **Lockout** — 5 failures per source address, then 15 minutes. Per-address and
  not per-account: there is one account, so a per-account counter is a denial
  of service anybody on the LAN can aim at the legitimate operator.
- **Timing** — username and password are always both checked and the results
  combined at the end, so a wrong username and a wrong password take the same
  time. Token and hash comparison is constant-time over `sha256` of both
  sides, so length does not leak either.

## One thing to be careful about

`loginMethods()` reports whether the backhaul is up, but **the decision about
whether local login is permitted does not consult it**. It keys on adoption
state.

That is deliberate. An attacker can cut a gateway's uplink — that is what
snipping a cable does. If losing the uplink re-enabled password login, cutting
the cable would be step one of every attack. Adoption state is something they
cannot change from outside.
