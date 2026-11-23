---
title: "Add-ons"
description: "An add-on is a feed package with an addon file: something a gateway runs that is not in its image, installed on request from a signed repository built for exactly the release the gateway runs:..."
---

An add-on is a feed package with an `addon` file: something a gateway runs
that is not in its image, installed on request from a signed repository
built for exactly the release the gateway runs: pulzr-modbus (Modbus),
pulzr-zigbee (Zigbee), pulzr-zwave (Z-Wave), pulzr-matter (Matter),
pulzr-thread (Thread), pulzr-ble (Bluetooth) and pulzr-cellular (Cellular).
The RAK7289CV2 carries pulzr-modbus in its image instead
(`PULZR_ADDONS_BUILTIN`), because its power board is already on a Modbus
bus, and the RAKs with a soldered LTE modem carry pulzr-cellular.

## One capability per add-on

Each add-on brings exactly one capability, so a deny on one never blocks
another: a gateway locked off Modbus can still have Zigbee. And each carries
its own binary, so a gateway carries only what it runs: pulzr-edge with every
module is over 10 MB on mipsel, more than a 32 MB RAK's overlay takes with the
installer's 2 MB to spare, while one module's binary is a few MB.

| Add-on | Brings | Binary |
|---|---|---|
| pulzr-modbus | `modbus` | `pulzr-edge` (Modbus buses) |
| pulzr-zigbee | `zigbee` | `pulzr-edge-zigbee` |
| pulzr-zwave | `zwave` | `pulzr-edge-zwave` |
| pulzr-matter | `matter` | `pulzr-edge-matter` |
| pulzr-ble | `ble` | `pulzr-edge-ble` (little-endian only: not on big-endian mips) |
| pulzr-thread | `thread` | OpenWrt's `openthread-br` |
| pulzr-cellular | `cellular` | OpenWrt's `modemmanager`, `usb-modeswitch`, `usbmuxd` and the modem kmods |
| pulzr-lorawan | `lorawan` | ChirpStack Concentratord and MQTT Forwarder, from this release's SDK build; OpenWrt's `mosquitto-ssl` |

The first five are pulzr-edge built with that module's feature alone (the SDK recipe
`sdk/packages/pulzr-edge`, which `ADDON_UPSTREAM` names). A radio runs where
its protocol's binary is installed: `pulzr-radios runnable` lists the radios
whose module is there and pulzr-edge-radios (in pulzr-probe, every image)
starts each with it, so a gateway locked off a capability, which never gets
its add-on, never runs it. A purge deletes only what the add-on's keep.d
names: pulzr-modbus its buses and maps; the radio add-ons nothing, because
`/etc/pulzr-edge/radios/` holds every protocol's network keys side by side and
is kept by pulzr-probe. `scripts/check-addons.sh` refuses an add-on with other
than one capability. A gateway that wanted pulzr-edge when it was the Modbus
add-on wants pulzr-modbus after the upgrade
(`/etc/uci-defaults/41-pulzr-addons-split`), so its buses keep running.

pulzr-cellular is offered, not just listed: a modem plugged into a gateway
that can take it is reported with its radios (`radios.modems`), and Pulzr
Net offers the add-on for it. See [backhaul.md](/PulzrOS/backhaul.html), "Cellular is
an add-on".

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
pulzr-addon restore [--retry|--carried]
pulzr-addon carry <version>
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
  feature words, upstream versions, titles, keep paths and whether each is
  carried, from the same generator. pulzr-addon decides with this file, never with the downloaded
  catalog.

sysupgrade drops installed packages with the old overlay. `pulzr-firmware
confirm` starts `pulzr-addon restore --retry` once the new firmware is kept,
never before: an add-on is never what the firmware gate judges.
`/etc/init.d/pulzr-addons` (START=99) starts it on every other boot, which
covers a rollback and a gateway that was offline at confirm. A restore that
cannot finish tries again after 15 minutes, doubling to six hours. An add-on
the running release does not have stays wanted, as `unavailable`.

### Carried across an upgrade

An add-on with `ADDON_CARRY="1"` may be the gateway's backhaul: pulzr-cellular
on a board whose modem is plugged in. It cannot wait for confirm, because a
gateway on that SIM alone comes back from the upgrade with no modem driver,
cannot reach Pulzr Cloud to be confirmed, and on a board with no card has no
image to roll back to. So:

- Before the upgrade, the console's firmware apply runs `pulzr-addon carry
  <version>`, the version from the image's signed manifest. Each installed
  carried add-on, that release's build of it, its signed index and every
  package the catalog says it brings are fetched into
  `/etc/pulzr/addons/carry/v<version>/<arch>/`, which `keep.d/pulzr` keeps.
  A gateway with no such add-on fetches nothing. If it cannot be fetched,
  or does not fit the overlay with the 2 MB to spare, the upgrade is refused.
- On the first boot, while the firmware is pending, the init script runs
  `restore --carried`: the copy is installed with apk against the same key,
  without the add-on gate (whose check needs the backhaul this may be), so
  the firmware gate judges the firmware and its backhaul together. The copy
  is deleted after, and on any boot of a release it was not fetched for.

It costs the add-on's size twice for the length of an upgrade, on the overlay
and in sysupgrade's backup in RAM, and the link nothing the restore would not
spend after the upgrade anyway.

### States

| State | Means |
|---|---|
| `installed` | the package is on the gateway, built in or not |
| `downloading`, `installing`, `removing` | a job is doing it now |
| `reverted` | installed, then undone because the gateway stopped reaching Pulzr Cloud; no longer wanted |
| `failed` | the last attempt did not install it; `error` says why |
| `pending-restore` | wanted and missing, and a restore has yet to put it back |
| `unavailable` | wanted, or asked for, and this release does not build it here |

An add-on that is neither wanted, installed, built in nor recorded is not
listed.

## The deny list

A gateway with Modbus denied (a production RAK7268CV2, say) never gets it. Three things hold it:

- No image but the RAK7289CV2's carries pulzr-modbus (`scripts/check-addons.sh`).
- `pulzr_addons.main.deny` holds capability words. `install` and `restore`
  refuse any package that brings one, asked for by name or as a dependency,
  so a `wanted` edited by hand does not bring it back. pulzr-modbus also
  `Provides: pulzr-cap-modbus`, and depends on nothing another capability
  brings, so denying Modbus leaves Zigbee and Z-Wave installable.
- Pulzr Net holds its own lock, and writes it back to the gateway through
  `POST /api/system/addons/deny` when a report's `addons.deny` lacks it (a
  factory reset wipes `/etc/config`).

A deny can be added remotely and never removed remotely. `pulzr-addon undeny`
is for somebody with a root shell.

## Who can ask

Installs and removals come from Pulzr Net, as a person: org admins and
Pulzr staff, never an API key, an agent or a bulk action. The gateway's half
of that is the session kind: its console API takes a write only from an `sso`
session, which only Pulzr Net mints, and audits it with the person's
subject. A local password or recovery session can read the list (System >
Maintenance > Add-ons) and gets `403 Add-ons are installed from Pulzr Net.`
for a write.

## The console API

Every POST needs the session's CSRF header, as every POST does.

`GET /api/system/addons` → `200`, `pulzr-addon status`:

```json
{"wanted":["pulzr-modbus"],"deny":[],
 "items":{"pulzr-modbus":{"state":"installed","version":"0.5.0-r202611201200",
   "upstream":"0.2.0","builtIn":false,"health":"idle","since":"2026-11-20T10:02:11Z",
   "error":"","title":"Modbus"}},
 "tag":"v0.5.0","arch":"mipsel_24kc","url":"https://assets.pkze.us/pulzros/addons/v0.5.0",
 "denyBy":null,"denyReason":null,"busy":null,
 "available":[{"name":"pulzr-modbus","title":"Modbus","caps":["modbus"],"feature":"modbus",
   "upstream":"0.2.0","builtIn":false}],
 "journal":[{"at":"2026-11-20T10:02:11Z","action":"install","name":"pulzr-modbus",
   "by":"admin@example.com","result":"installed","version":"0.5.0-r202611201200"}]}
```

`busy`, while a job runs: `{"action","name","by","since"}`. `journal` is the
last 20 entries.

`POST /api/system/addons` with `{"name":"pulzr-modbus","action":"install"}` or
`{"name":"pulzr-modbus","action":"remove","purge":false}`:

- `202 {"ok":true,"name":"pulzr-modbus","action":"install","purge":false}`: the
  job is running; its outcome is in `GET` and in the next report, which the
  job sends itself when it finishes.
- `400 {"error":…}`: not an add-on name, or not install or remove.
- `403 {"error":"Add-ons are installed from Pulzr Net."}`: not an `sso` session.
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
{"wanted":["pulzr-modbus"],"deny":[],"items":{"pulzr-modbus":{"state":"installed",
 "version":"0.5.0-r202611201200","upstream":"0.2.0","builtIn":false,"health":"idle",
 "since":"2026-11-20T10:02:11Z","error":""}}}
```

A report without the key is firmware older than add-ons.

The MQTT agent's `addons` op answers with the same document, and `all` (and
so the retained `state`) includes it as `"addons"`. A read only: an install
takes minutes and the agent answers one request at a time.

## In use by its configuration

An add-on may name one UCI option, `ADDON_CONFIG`, that says the gateway uses
it: pulzr-lorawan's is `pulzr.concentrator.present`, the slots that answered.
`/etc/config` is kept across a sysupgrade, as the WiFi a gateway joins is, so
the option outlives the package. Every restore (each boot, and after
`pulzr-firmware confirm`) adds an add-on whose option is set to anything but
empty or `0`, and that is not installed, built in or locked off, to `wanted`;
the restore then installs it from this release's repository like any wanted
add-on. It is `pending-restore` meanwhile, with the last try's error while the
repository cannot be reached, and the restore tries again from 15 minutes,
doubling to six hours. Nothing in it names a release or a board: a Pi
upgraded out of an image that carried LoRaWAN, and a gateway whose package
was lost, are the same case.

Removing the add-on deletes that one option and keeps every other setting, so
the next restore leaves it removed and a later install finds its settings.

## Features

`system.features()` adds each installed add-on's `ADDON_FEATURE` word
(`modbus`) to the board's `PULZR_FEATURES`. An add-on counts as installed
while its addon-health script is on the gateway, which apk takes away with
the package. See [features.md](/PulzrOS/features.html).

## Adding an add-on

1. A feed package with an `arches` file covering every board its
   `ADDON_BOARDS` allows, and an `addon` file: `ADDON_TITLE`, `ADDON_CAPS`,
   `ADDON_FEATURE` (or empty), `ADDON_BOARDS`, `ADDON_CARRY="1"` if a
   gateway's backhaul may depend on it, and `ADDON_CONFIG` if one UCI option
   says the gateway uses it. An architecture on which every
   allowed board carries it built in is not published.
2. `Provides: pulzr-cap-<cap>` in its control file for each cap.
3. `files/usr/libexec/pulzr/addon-health/<name>`, executable.
4. Its settings in `files/lib/upgrade/keep.d/<name>`.

`scripts/check-addons.sh` checks all four, and that no board but the
RAK7289CV2 carries pulzr-modbus.

## OpenWrt packages an add-on brings

An add-on whose work is an OpenWrt package names it in `feed/<name>/upstream`
(pulzr-thread brings `openthread-br`). `scripts/addon-upstream.sh` fetches it
and its dependencies for each architecture from the release's own feeds, with
apk checking each against OpenWrt's signed index, and `build-addons.sh` puts them in the
repository unchanged: built by OpenWrt's buildbots from OpenWrt's recipe, never
by us. The catalog lists them under `upstream`, each with the add-ons that bring
it (`by`), and `pulzr-addon` installs a package that is not an add-on only when
the catalog says the add-on being installed brings it, and never a `pulzr-`
one. Removing the add-on lets apk remove what only it needed.

A kernel module is built for one kernel, and the repository has one directory
per architecture. So `build-addons.sh` publishes the kmods an add-on brings
only where every board that may install it on that architecture runs one
target: they are that target's own, from the kmods feed named for the
release's kernel, which the images' ImageBuilder installs from too, and apk
holds each to the kernel package the gateway has installed. pulzr-cellular's
QMI, MBIM, option, Huawei NCM, CDC Ethernet, NCM, RNDIS and ipheth modules
come this way. On an architecture whose boards run more than one target, a
module an add-on needs must be in every image (`PACKAGES_COMMON`), and
`build-addons.sh` refuses otherwise. After an install pulzr-addon runs
`kmodloader` once, before anything else the add-on brought starts. A target
OpenWrt does not build (the GL-SFT1200's siflower) has no feeds of its own, so
its side comes from that board's ImageBuilder, the one its image is built
from: kernel, kmods and toolchain libraries. A toolchain library an upstream
package needs (openthread-br's `libstdcpp6`) is then shipped from that build;
the rest is still OpenWrt's arch feed.

A package OpenWrt does not build at all is ours, from this release's SDK build
(`sdk/build.sh`, in `.build/sdk/<arch>`): pulzr-lorawan's ChirpStack
Concentratord and MQTT Forwarder, from ChirpStack's own OpenWrt recipes,
the same files the images that carry pulzr-lorawan install. They go in the
same way as a source-only target's: `addon-upstream.sh` indexes them under a
key made for that run, fetches with apk from that index beside OpenWrt's, and
`build-addons.sh` signs the repository's index over them with the add-ons key,
so a gateway checks them exactly as it checks the rest. busybox, which the SDK
also builds, is the image's and never an add-on's.
