# Contributing

Thanks for helping. Bug reports, board support, documentation and fixes are all
welcome.

## Before you start

- Read [`CLAUDE.md`](CLAUDE.md) (it applies to people too): the console's text
  rules, the checks that exist because something shipped broken, and the
  `uci-defaults` guard every script needs.
- For anything bigger than a fix, open an issue first so the design can be
  discussed before you write it.
- Security problems go to [`SECURITY.md`](SECURITY.md), not to an issue.

## Make a change

1. Fork, and branch from `main`.
2. Keep a change to one thing. A board is `boards/<id>/board.conf` and nothing
   else if you can help it ([`docs/boards.md`](docs/boards.md)).
3. Run the checks that apply. They are listed in the README; at minimum
   `scripts/check-ucode.sh`, `scripts/check-ucode-scope.py`, the `scripts/test-*.sh`
   that touch what you changed, and `npm run typecheck` in `console/` for the UI.
   Do not work around a failing check.
4. Comments say why, not what. A comment worth keeping records a decision that
   looks wrong until you know what it cost.
5. No emoji anywhere: a color glyph does not render on a serial console.
6. Open a pull request describing what changed and how you tested it. Say which
   board, if it ran on hardware.

## Sign your work (DCO)

Every commit needs a `Signed-off-by` line, which certifies the
[Developer Certificate of Origin](https://developercertificate.org/) 1.1: you
wrote the change, or have the right to submit it under the project's licence.

```
git commit -s -m "Fix the thing"
```

adds `Signed-off-by: Your Name <you@example.com>` using your git identity.
Pull requests with unsigned commits will be asked to amend them
(`git rebase --signoff`).

## Licence of contributions

Your contribution is licensed under the licence of the file it changes:
Apache-2.0 for the project's own code ([`LICENSE`](LICENSE)), or the file's own
licence where it says so ([`NOTICE`](NOTICE),
[`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md)). Do not paste in code you
cannot license that way.

## Conduct

By taking part you agree to the [Code of Conduct](CODE_OF_CONDUCT.md).
