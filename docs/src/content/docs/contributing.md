---
title: "Contributing"
description: "Bug reports, board support, documentation and fixes are welcome."
---

Bug reports, board support, documentation and fixes are welcome. For anything bigger than a fix, open an issue first so the design is agreed before you write it. Security problems go to security@pulzr.net, not an issue.

## Set up

```bash
git clone https://github.com/pulzar-net/PulzrOS
cd PulzrOS
```

The console:

```bash
cd console && npm install && npm run typecheck && npm run build
```

The console's API, the TUI and much of the device code is [ucode](https://github.com/jow-/ucode), which does not ship for macOS or Ubuntu. Build it once:

```bash
git clone --depth 1 https://github.com/jow-/ucode /tmp/ucode
cmake -B /tmp/ucode/build -DFS_SUPPORT=ON -DMATH_SUPPORT=ON /tmp/ucode
cmake --build /tmp/ucode/build
export UCODE=/tmp/ucode/build/ucode
```

Image builds need Linux or Docker: see [Building from source](/PulzrOS/building.html).

## Checks

CI runs all of these on every pull request. Run the ones that touch your change; do not work around a failing one.

| Check | What it catches |
|---|---|
| `scripts/check-ucode.sh` | ucode that does not compile the way its loader runs it, or imports a function the stubs in `scripts/ucode-stubs/` lack |
| `python3 scripts/check-ucode-scope.py` | forward references: ucode does not hoist functions |
| `scripts/check-printf.sh` | `printf` arguments that do not match their format |
| `scripts/check-commands.sh` | a script calling a command the image lacks |
| `scripts/check-deps.sh` | a package that does not exist in the pinned OpenWrt release |
| `scripts/check-addons.sh` | add-on packaging and which boards may carry them |
| `npm run typecheck` in `console/` | the console |

CI also checks shell syntax, JSON, that device scripts are POSIX `sh` (OpenWrt ships ash, not bash), and that every `uci-defaults` script starts with the `IPKG_INSTROOT` guard.

## Tests

Shell and ucode that only runs on a gateway is tested against stubs and fixtures:

```bash
for t in scripts/test-*.sh; do bash "$t" || echo "FAILED: $t"; done
```

| Test | Covers |
|---|---|
| `test-claim.sh` | a revoked claim and back |
| `test-report-stats.sh` | the stats in the gateway's report |
| `test-apply.sh` | a change undone unless confirmed in time |
| `test-ssh-setup.sh` | what sshd trusts |
| `test-cellular-watchdog.sh` | cellular recovery |
| `test-firmware-stash.sh` | the firmware journal and rollback image |
| `test-legacy.sh` | migration from ParkezeOS paths |
| `test-setup-mode.sh` | the reset button and the setup AP |
| `test-hwdesc.sh` | the RAK hardware descriptor and named reset lines |
| `test-led.sh` | LED drivers against a fake sysfs |
| `test-rak-power.sh` | the RAK power board on a simulated bus (needs Lua 5.1 and libmodbus) |
| `test-router.sh` | uplinks and DNS failover (needs `UCODE`) |
| `test-wifi-uplink.sh` | the WiFi verdict and roaming (needs `UCODE`) |
| `test-addon.sh` | installing, refusing and restoring add-ons (needs `UCODE`) |
| `test-figlet.sh` | the banner renderer against `figlet` (needs `UCODE`) |

`scripts/run-tui.sh` runs the terminal UI on canned state.

## Style

- **Comments say why, not what.** Keep the ones that record a decision that looks wrong until you know what it cost.
- **No emoji**, anywhere. A color glyph does not render on a serial console.
- **Console text is for a technician.** No subtitles, no explanatory paragraphs, nothing said twice on one screen. Say "the LNS", not the server's product name. The rules are in [`CLAUDE.md`](https://github.com/pulzar-net/PulzrOS/blob/main/CLAUDE.md).
- **Commit messages** say what changed and why, in a sentence: `oui lookup: no day-long cache lifetime, which kept a timer alive`. One change per commit.
- **No secrets, no customer or site names** in code, comments, docs or commits. The repository is public.

## Sign your work

Every commit needs a `Signed-off-by` line certifying the [Developer Certificate of Origin](https://developercertificate.org/) 1.1:

```bash
git commit -s -m "Fix the thing"
```

Forgot? `git rebase --signoff main`.

## Adding a board

A board is `boards/<id>/board.conf`, a page of deltas over `boards/common/board.conf`. Its Hardware page on this site is generated from that file. The steps, the concentrator slot syntax and LED mapping are in [Adding a board](/PulzrOS/boards.html); what a feature word brings is in [Board features](/PulzrOS/features.html).

On hardware, check setup mode with [Setup mode on a real gateway](/PulzrOS/setup-mode-validation.html) and say which board you ran it on in the pull request.

## Pull requests

Describe what changed and how you tested it. Name the board if it ran on hardware. Keep a pull request to one thing. Contributions are licensed under the license of the file they change: Apache-2.0 for the project's own code.

By taking part you agree to the [Code of Conduct](https://github.com/pulzar-net/PulzrOS/blob/main/CODE_OF_CONDUCT.md).
