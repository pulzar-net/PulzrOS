# Operator SSH keys

Every `*.pub` in this directory is baked into `/etc/dropbear/authorized_keys`
at image build time, so a freshly flashed gateway accepts these keys straight
away — no password to read off the card, nothing to copy, nothing to type.

**Public keys only.** Nothing here is secret; the private halves stay on the
machines that own them. `.gitignore` refuses anything that looks like a private
key.

## What this costs

One private key is root on every gateway built with its public half. That is
the same shape of risk as a shared default password, and it is a better version
of it rather than an escape from it: a private key is never typed, pasted into
a ticket, or read out over a phone, and rotating it is a rebuild.

So keep this directory to people who genuinely need bench access, and for a
production build either use a key held by whoever operates the fleet or leave
it out entirely:

```
PARKEZE_OPS_KEYS=0 ./build.sh --board rpi3
```

This does not replace the per-unit password on the boot partition. That one is
for an installer standing in front of a gateway; this one is for us. They
answer to different people, which is why both exist.
