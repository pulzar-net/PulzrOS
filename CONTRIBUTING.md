# Contributing to PulzrOS

Bug reports, board support, documentation and fixes are welcome.

The contributor guide is on the docs site: **[pulzar-net.github.io/PulzrOS/contributing](https://pulzar-net.github.io/PulzrOS/contributing)**. It covers setup, the checks, the tests, and adding a board.

## In short

1. **Open an issue first** for anything bigger than a fix, so the design is agreed before you write it.
2. **Keep a change to one thing.** A new board is `boards/<id>/board.conf` and little else ([Adding a board](https://pulzar-net.github.io/PulzrOS/boards)).
3. **Run the checks that touch your change**: `scripts/check-ucode.sh`, `scripts/check-ucode-scope.py`, the `scripts/test-*.sh` for what you changed, and `npm run typecheck` in `console/`. Do not work around a failing check.
4. **Follow [CLAUDE.md](CLAUDE.md)**: it applies to people too. Comments say why, not what. Console text is for a technician. No emoji anywhere.
5. **Sign off every commit** (`git commit -s`), certifying the [Developer Certificate of Origin](https://developercertificate.org/) 1.1.
6. **Say how you tested it** in the pull request, and which board if it ran on hardware.

No secrets, and no customer or site names, in code, comments, docs or commits: the repository is public.

Security problems go to security@pulzr.net ([SECURITY.md](SECURITY.md)), not to an issue.

## License

Your contribution is licensed under the license of the file it changes: Apache-2.0 for the project's own code ([LICENSE](LICENSE)), or the file's own license where it says so ([NOTICE](NOTICE), [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)).

By taking part you agree to the [Code of Conduct](CODE_OF_CONDUCT.md).
