# Security policy

## Reporting a vulnerability

Email **security@pulzr.net**. Please do not open a public issue or pull request
for a suspected vulnerability.

Include what you found, the version (`PULZR_VERSION` in `/etc/pulzr/board.conf`,
or the image name), the board, and the steps to reproduce it. If you want to
send details privately, say so in a first message and we will arrange it.

We aim to acknowledge a report within three working days, to tell you what we
have decided within ten, and to credit you in the release notes unless you
prefer not to be named. Please give us a reasonable time to ship a fix before
you disclose.

## What is in scope

PulzarOS gateway software: the console and its API, the terminal UI, adoption
and claim handling, the management tunnel, the SSH and recovery trust model
([`docs/auth.md`](docs/auth.md)), the firmware update check, and the image
build. A flaw in OpenWrt or another upstream component is best reported
upstream; tell us as well if PulzarOS's configuration makes it worse.

## Supported versions

The latest release. Older images should be upgraded; a gateway can be upgraded
from its console or with `sysupgrade`
([`docs/flashing.md`](docs/flashing.md)).

## Keys and secrets

No secret belongs in this repository. The public halves of the recovery,
firmware-signing and SSH CA keys are supplied at build time
(`PULZR_RECOVERY_PUBKEY`, `PULZR_FIRMWARE_PUBKEY`, `PULZR_SSH_CA_PUBKEY`). If you
find a private key, a password or a token committed here, report it the same
way.
