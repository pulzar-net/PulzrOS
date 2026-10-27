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
`/dev/urandom`, and on the label, the boot partition of a Pi
(`parkeze-initial-password.txt`) and the root login banner. It is not
`parkeze/parkeze` — which is what the previous ParkezeOS shipped on every
image, and which means one published README is root on the entire fleet. It is
the console's password and nothing else: root has none (below).

The cleartext copy lives at `/etc/parkeze/console/initial-password`, mode 0600,
so an installer can read it off the device. The console nags on every page
until it is changed, and deletes the cleartext the moment it is.

### 2. Adopted and online

parkeze.net is the identity provider. The console accepts a signed one-time
handoff token minted by `recovery-service`, so an operator already
authenticated centrally lands signed in without a second password.

**Local password login is disabled on adoption** — `parkeze.console.local_login`
goes to `0` — not merely discouraged.

The terminal UI has no browser to receive that handoff, so it collects the same
token itself: it shows a code, somebody approves it on parkeze.net from a
phone, and the gateway picks the token up. The token is marked for the terminal
and for that one request, and the web console refuses tokens marked for
anything. See [`tui.md`](tui.md).

### 3. Adopted and offline

The interesting case. Local login stays refused, because the credential a thief
could extract must not be a way in. Instead: an Ed25519 challenge-response
against a key the gateway only ever holds the **public** half of.

### On the bench: a LAN window

The ethernet port's firewall admits only `169.254.0.0/16` and the console
subnet, so a gateway on a bench LAN is reachable only through parkeze.net.
From a root shell (SSH as root, or the serial console of a development image):

```
parkeze-local-access open [minutes]   # default 60, at most 1440
parkeze-local-access close
parkeze-local-access status
```

`open` admits the subnet of the port's DHCP lease on 22, 80 and 443, and prints
a one-time sign-in link. Running it again extends the window and prints a new
link. The session the link opens ends when that window closes, and does not come
back if another window is opened later.

None of this is a way past the rules above. Opening a window takes root, and
root can already read everything on the box. There is no API for it. The rule,
the window and the link live in `/var/run`, so a reboot closes all of it.

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
- Every recovery is authorized and audited centrally, even though the gateway
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

## SSH

OpenSSH's `sshd` on port 22, on every board. dropbear, which every image
before it ran, cannot check a certificate, and certificates are how
parkeze.net reaches a gateway's shell: one signed for this gateway's EUI and
nothing else, valid for five minutes, `permit-pty` only for the browser
terminal. A certificate leaked from one session opens one gateway for five
minutes. parkeze.net's `docs/gateway-ssh-certificates.md` is the other half.

What sshd trusts is written at every boot by `parkeze-ssh-setup`:

| File | From |
|---|---|
| `/etc/ssh/sshd_config` | `/usr/share/parkeze/ssh/sshd_config` in the image |
| `/etc/ssh/parkeze_user_ca.pub` | `boards/common/ssh/parkeze_user_ca.pub` in this repo, via the image |
| `/etc/ssh/sshd_config.d/parkeze-ca.conf` | `TrustedUserCAKeys` and `AuthorizedPrincipalsFile` |
| `/etc/ssh/auth_principals/root` | the gateway's EUI, 16 lowercase hex |
| `/root/.ssh/authorized_keys` | the fleet key; on a development image also `boards/common/ssh/dev/` and site keys (`parkeze-fleet-keys`) |

Rewritten from the image each boot rather than kept, because sysupgrade keeps
conffiles and `/etc/ssh/sshd_config` is one: a change shipped in a release
would otherwise never reach a gateway that had been upgraded once. The fleet
key stays in `authorized_keys` until every gateway trusts the CA. parkeze.net
uses a certificate only for a gateway marked as trusting the CA, and only with
`GATEWAY_SSH_CERTIFICATES` set. Staff mark it today; the report carries
`sshCa: true` once the running sshd trusts the CA, for net-api to mark it
itself.

**Host keys.** parkeze.net pins the key a gateway reports, so the first boot
without dropbear converts dropbear's keys (`dropbearconvert`) and sshd presents
the key already pinned. dropbear's files stay, and keep.d carries both, so a
rollback to a dropbear image presents the same key again.

**Checking one.** On the gateway:

```
sshd -T | grep -Ei 'trustedusercakeys|authorizedprincipalsfile'
cat /etc/ssh/auth_principals/root
logread | grep parkeze-net          # the key ID of every certificate login
```

An image built without `boards/common/ssh/parkeze_user_ca.pub` gets no CA
configuration and is reached with the fleet key, as before.

**Rotating the CA** is a firmware release: put the new public line in
`boards/common/ssh/`, ship it, and only then switch recovery-service to the
new private key. A gateway trusts exactly one CA, so a gateway on the old
release refuses the new CA's certificates until it upgrades.

### The keys in this repo

All public; nothing in `boards/common/ssh/` is secret.

| Path | What it is |
|---|---|
| `fleet/*.pub` | baked into root's `authorized_keys` (`install_ops_keys` in `build.sh`) |
| `parkeze_user_ca.pub` | the CA above; one `ssh-ed25519` line, copied from parkeze.net's `secrets/parkeze_ssh_ca.pub` |
| `dev/*.pub` | people's keys for a development image, ignored by git |

The CA is outside the `fleet/` glob on purpose: in `authorized_keys` its
private half would open every gateway directly, and `build.sh` refuses an
image that puts it there.

`fleet/parkeze-fleet.pub`'s private half is parkeze.net's, not a person's:
`tools/generate-fleet-ssh-key.sh` in that repo makes the pair and gateway-link
mounts the private half. Access follows whoever runs the platform, and no
laptop key ships in an image. It is RSA because gateways still on a dropbear
image accept nothing else. To use it locally:

```bash
# in parkeze.net
tools/generate-fleet-ssh-key.sh secrets
cp secrets/fleet_ssh_rsa.pub ../ParkezeOS/boards/common/ssh/fleet/parkeze-fleet.pub
ssh -i secrets/fleet_ssh_rsa root@192.168.61.1
```

Rotating it is a rebuild: a new pair, then reflash or push the new
`authorized_keys` over the management tunnel with the old key. No re-adoption.
`PARKEZE_OPS_KEYS=0 ./build.sh <board>` builds an image with no fleet key at
all, reached only by certificate.

## Who gets root

A root shell on ParkezeOS is a copy of ParkezeOS, so on a production image it
is Parkeze's: the fleet key, the certificates parkeze.net signs for staff, and
a console session parkeze.net has signed as staff's. An organization's admin
runs their gateway through the console — the web console, the TUI on a port,
and parkeze.net's **Console** (`parkeze-tui --remote`, see
[`tui.md`](tui.md)) — and never gets the shell under it. Before 0.3.1 root's
password was the console's, so anybody with the label was root.

| | Production image | Development image |
|---|---|---|
| Root's password | none (`*`, `parkeze-root-keys-only`) | none |
| SSH as root | fleet key, staff certificate | also `boards/common/ssh/dev/*.pub`, site keys |
| SSH with a password | refused | refused |
| `ssh parkeze@<gateway>` | the TUI, behind the console's sign-in | the same |
| Serial console | the TUI, behind the console's sign-in | the stock root shell |
| HDMI, USB serial | the TUI, behind the console's sign-in | the same |
| The TUI's `!` | a staff session, or a TUI started from a root shell | any signed-in session |
| Failsafe mode | off | on |
| Site keys on the card | ignored, and removed from a gateway that has them | accepted until adopted |

**`ssh parkeze@<gateway>`** is how a technician on the site network reaches
the console, where the label's password used to open a root shell. `parkeze`
is uid 0 with no password of its own (`parkeze-ssh-setup` writes it after
root's line every boot), and sshd's `Match User parkeze` block runs
`parkeze-tui --console` whatever the client asks for — no command, sftp,
forwarding or `~/.ssh/rc`. So the account is the console's sign-in and nothing
else: the local password while it is allowed, Parkeze or recovery once adopted,
and `!` only for staff. Sign-in failures count against the client's address,
and Ctrl-C ends the session.

**Staff sessions.** Organization admins sign in to a gateway's console with
Parkeze and with recovery as well as staff do, so the kind of session cannot
say who it is. parkeze.net says it, signed with the recovery key the gateway
already trusts: a terminal sign-in approved by staff carries `shell: true` in
its token, and staff recovering a gateway are given a signature over
`<challenge>.shell` instead of over the challenge. `auth.uc` records either as
the session's `shell`; nothing a client sends can set it. The web console has
no shell, and a token for it cannot carry the mark.

**Upgrading.** `parkeze-root-keys-only` runs at every boot, so a gateway from
an older release loses root's password on its first boot of this one. The
serial console moves to the TUI from the boot after that, because procd reads
`/etc/inittab` once; on the first boot `system.ttylogin` makes the stock login
ask for root's password, which no longer exists.

**A development image** is `PARKEZE_DEV=1 ./build.sh <board>`. Its version
ends in `-dev`, which parkeze.net shows, and CI refuses to build one, so a
release never is. Put your public key in `boards/common/ssh/dev/` (ignored by git).

**What this does not cover** is the hardware. A Pi's root filesystem is a
plain squashfs on its SD card, and a RAK's is in flash its U-Boot will hand to
anybody on the serial header; either can be read by somebody holding the
gateway. Closing that is secure boot and encrypted storage, which a Pi 4 or 5
can be made to do and the MT7628 cannot.
