# Working in this repo

## The UI

**No subtitles.** A page gets a title. It does not get a line under the title
explaining what the page is. Every page here had one once and none earned its
line: they either restated the title as a sentence or repeated a fact the
cards below already show with a label.

`PageHeader` has no `subtitle` prop for this reason. Do not add one back.

**Write for a technician.** Whoever is reading this is standing at a gateway
with a job to finish. The claim screen used to explain scanning a QR code in
three numbered steps. Say the thing; do not warm up to it.

**Do not say the same thing twice on one screen.** The sign-in page rendered
the API's note *and* a notice that said the same sentence. The second one
teaches people to skip the first.

**No emoji.** `scripts/check-no-emoji.py` fails the build on one. Status is
carried by badges, icons and colour. A colour glyph does not render on a serial
console at 115200 either.

**Say "the LNS", not "ChirpStack"**, in anything a user reads.

## Checks that exist because something shipped broken

Run them; do not work around them.

- `scripts/check-ucode-scope.py` — ucode does not hoist function declarations.
  A forward reference compiles and throws at runtime. There were twelve.
- `scripts/check-ucode.sh` — compiles each `.uc` the way its actual loader
  does, and asserts the two things compiling cannot catch: the `{%` wrapper and
  the bare `handle_request` assignment. It used to pass `-cmodule` to
  everything, which is how a console that could never start shipped in every
  image.
- `scripts/check-deps.sh` — every package resolves against the real upstream
  indexes.

## uci-defaults

Every script starts with the `IPKG_INSTROOT` guard. Without it OpenWrt runs it
at image-assembly time against the build host, which has baked one shared
password into every gateway before now.

## Comments

Explain why, not what. The comments worth having are the ones recording a
decision that looks wrong until you know what it cost — `parkeze-tailscale`
and `20-parkeze-network` are the shape of it.
