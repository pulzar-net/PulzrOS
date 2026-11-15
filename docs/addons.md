# Add-ons

An add-on is a feed package with an `addon` file: something a gateway runs
that is not in its image, installed on request from a signed repository
built for exactly the release the gateway runs. Today there is one,
pulzr-edge (Modbus). The RAK7289CV2 carries it in its image instead
(`PULZR_ADDONS_BUILTIN`), because its power board is already on a Modbus bus.

The design and the decisions behind it are in the logbook's
`docs/plans/pulzros-addons.md`. This page is what is built.

## The repository

```
https://assets.pkze.us/pulzros/addons/<tag>/addons.json
https://assets.pkze.us/pulzros/addons/<tag>/<arch>/packages.adb
https://assets.pkze.us/pulzros/addons/<tag>/<arch>/<name>-<pkgver>.apk
```

Public, and immutable per tag. `scripts/build-addons.sh` builds it and the
`addons` job uploads it on a tag. The index is signed with the ECDSA key
whose public half is `feed/pulzr-base/files/etc/apk/keys/pulzr-addons.pem`;
apk checks that signature and each package's hash against the index. The
catalog, `addons.json`, is display data and is not signed; its sha256 for
each package is checked only so a damaged download is thrown away before apk
reads it.

The gateway never chooses a version. It builds the URL from its own
`PULZR_ADDONS_URL` and `PULZR_VERSION` (`<url>/v<version>`), and every add-on
depends on this release's exact `pulzr-base`, so apk refuses one built for
another release however it was served. Staff can point a bench unit, whose
`-dev` build has no published repository, at another base with
`uci set pulzr_addons.main.url=…`; the signature and the pin still apply.

## On the gateway

`pulzr-addon` (pulzr-base) does everything:

```
pulzr-addon status [--brief]
pulzr-addon start install|remove <name> <issuer> [--purge]
pulzr-addon install <name> <issuer>
pulzr-addon remove <name> <issuer> [--purge]
pulzr-addon restore [--retry]
pulzr-addon deny <issuer> <reason> <cap>...
pulzr-addon undeny <cap>...
```

An install refuses, in one sentence each, before it downloads anything: a
name that is not one, an add-on this release does not have, one built into
the board, one that brings a denied capability, one already installed, a
firmware upgrade still being judged, and another add-on job holding the lock
(`/var/run/pulzr/addon.lock`). Then it fetches the catalog and the index,
asks `apk add --simulate` what would be installed, and refuses again if any
of it is not an add-on of this release, brings a denied capability, or does
not fit the overlay with 2 MB to spare. The gateway must pass
`pulzr-health-gate --check` before the packages are downloaded, because
otherwise the result could not be judged.

Packages go to the card (`<mount>/pulzr/addons/<tag>/<arch>/`) when there is
one, otherwise `/tmp/pulzr-addons/…`, with `curl -C -`: a download cut off
half way resumes where it stopped. The catalog and index are a few KB and are
fetched anew each time.

After `apk add`, pulzr-addon does what image assembly would: runs and
deletes the package's uci-defaults, and enables and starts its init scripts.
Then the gate: after 60 seconds, `pulzr-health-gate --check` every 30 seconds
for up to five minutes. If it never passes, the add-on is stopped, removed
and recorded as `reverted`. The add-on's own health
(`/usr/libexec/pulzr/addon-health/<name>`: 0 ok, 2 idle, 1 failing) is
reported and never acted on.

`remove` stops and disables the services, runs `apk del` and drops the name
from `wanted`. The add-on's settings (its keep.d paths, `/etc/pulzr-edge/`)
stay unless `--purge`.

### What is kept, and the restore

- `/etc/config/pulzr_addons`: `config addons 'main'` with `list wanted`,
  `list deny`, `deny_by`, `deny_reason` and an optional `url`, and one
  `config addon` section per add-on with its last `state`, `since` and
  `error`. Its own config, not `pulzr`, because pulzr-edge restarts on every
  change to that one. Created by `40-pulzr-addons`.
- `/etc/pulzr/addons/journal`: one JSON line per install, removal, refusal,
  deny and revert, with who asked. Kept by `keep.d/pulzr`.
- `/lib/upgrade/keep.d/pulzr-addons`: every add-on's keep.d, generated into
  pulzr-base by `scripts/addon-index.sh`, so settings survive an upgrade that
  finds the add-on missing.
- `/usr/share/pulzr/addons.caps`: the release's add-ons, their capabilities,
  feature words, upstream versions, titles and keep paths, from the same
  generator. pulzr-addon decides with this file, never with the downloaded
  catalog.

sysupgrade drops installed packages with the old overlay. `pulzr-firmware
confirm` starts `pulzr-addon restore --retry` once the new firmware is kept,
never before: an add-on is never what the firmware gate judges.
`/etc/init.d/pulzr-addons` (START=99) starts it on every other boot, which
covers a rollback and a gateway that was offline at confirm. A restore that
cannot finish tries again after 15 minutes, doubling to six hours. An add-on
the running release does not have stays wanted, as `unavailable`.

### States

| State | Means |
|---|---|
| `installed` | the package is on the gateway, built in or not |
| `downloading`, `installing`, `removing` | a job is doing it now |
| `reverted` | installed, then undone because the gateway stopped reaching Pulzar Cloud; no longer wanted |
| `failed` | the last attempt did not install it; `error` says why |
| `pending-restore` | wanted and missing, and a restore has yet to put it back |
| `unavailable` | wanted, or asked for, and this release does not build it here |

An add-on that is neither wanted, installed, built in nor recorded is not
listed.

## The deny list, and Osborne

USC PTS's Osborne (RAK7268CV2) never gets Modbus. Three things hold it:

- No image but the RAK7289CV2's carries pulzr-edge (`scripts/check-addons.sh`).
- `pulzr_addons.main.deny` holds capability words. `install` and `restore`
  refuse any package that brings one, asked for by name or as a dependency,
  so a `wanted` edited by hand does not bring it back. pulzr-edge also
  `Provides: pulzr-cap-modbus`.
- Pulzar Net holds its own lock, and writes it back to the gateway through
  `POST /api/system/addons/deny` when a report's `addons.deny` lacks it (a
  factory reset wipes `/etc/config`).

A deny can be added remotely and never removed remotely. `pulzr-addon undeny`
is for somebody with a root shell.

## Who can ask

Installs and removals come from Pulzar Net, as a person: org admins and
Pulzar staff, never an API key, an agent or a bulk action. The gateway's half
of that is the session kind: its console API takes a write only from an `sso`
session, which only Pulzar Net mints, and audits it with the person's
subject. A local password or recovery session can read the list (System >
Maintenance > Add-ons) and gets `403 Add-ons are installed from Pulzar Net.`
for a write.

## The console API

Every POST needs the session's CSRF header, as every POST does.

`GET /api/system/addons` → `200`, `pulzr-addon status`:

```json
{"wanted":["pulzr-edge"],"deny":[],
 "items":{"pulzr-edge":{"state":"installed","version":"0.5.0-r202611201200",
   "upstream":"0.2.0","builtIn":false,"health":"idle","since":"2026-11-20T10:02:11Z",
   "error":"","title":"Modbus"}},
 "tag":"v0.5.0","arch":"mipsel_24kc","url":"https://assets.pkze.us/pulzros/addons/v0.5.0",
 "denyBy":null,"denyReason":null,"busy":null,
 "available":[{"name":"pulzr-edge","title":"Modbus","caps":["modbus"],"feature":"modbus",
   "upstream":"0.2.0","builtIn":false}],
 "journal":[{"at":"2026-11-20T10:02:11Z","action":"install","name":"pulzr-edge",
   "by":"admin@example.com","result":"installed","version":"0.5.0-r202611201200"}]}
```

`busy`, while a job runs: `{"action","name","by","since"}`. `journal` is the
last 20 entries.

`POST /api/system/addons` with `{"name":"pulzr-edge","action":"install"}` or
`{"name":"pulzr-edge","action":"remove","purge":false}`:

- `202 {"ok":true,"name":"pulzr-edge","action":"install","purge":false}`: the
  job is running; its outcome is in `GET` and in the next report, which the
  job sends itself when it finishes.
- `400 {"error":…}`: not an add-on name, or not install or remove.
- `403 {"error":"Add-ons are installed from Pulzar Net."}`: not an `sso` session.
- `409 {"error":…}`: refused before starting. Built in, locked off
  (`Modbus is locked off on this gateway.`), already installed, not
  installed, not in this release, a firmware upgrade being judged, another
  add-on job running.

Audited as `system.addon.install` or `system.addon.remove`, `{by, name}`.

`POST /api/system/addons/deny` with `{"deny":["modbus"],"reason":"…"}` →
`200 {"deny":["modbus"]}`. Adds to the list; `403` without `sso`. Audited as
`system.addon.deny`.

## Reports and MQTT

`pulzr-claim report` carries `"addons"`, `pulzr-addon status --brief`, or
`null` when it cannot say:

```json
{"wanted":["pulzr-edge"],"deny":[],"items":{"pulzr-edge":{"state":"installed",
 "version":"0.5.0-r202611201200","upstream":"0.2.0","builtIn":false,"health":"idle",
 "since":"2026-11-20T10:02:11Z","error":""}}}
```

A report without the key is firmware older than add-ons.

The MQTT agent's `addons` op answers with the same document, and `all` (and
so the retained `state`) includes it as `"addons"`. A read only: an install
takes minutes and the agent answers one request at a time.

## Features

`system.features()` adds each installed add-on's `ADDON_FEATURE` word
(`modbus`) to the board's `PULZR_FEATURES`. An add-on counts as installed
while its addon-health script is on the gateway, which apk takes away with
the package. See [features.md](features.md).

## Adding an add-on

1. A feed package with an `arches` file covering every board its
   `ADDON_BOARDS` allows, and an `addon` file: `ADDON_TITLE`, `ADDON_CAPS`,
   `ADDON_FEATURE` (or empty), `ADDON_BOARDS`.
2. `Provides: pulzr-cap-<cap>` in its control file for each cap.
3. `files/usr/libexec/pulzr/addon-health/<name>`, executable.
4. Its settings in `files/lib/upgrade/keep.d/<name>`.

`scripts/check-addons.sh` checks all four, and that no board but the
RAK7289CV2 carries pulzr-edge.
