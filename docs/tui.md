# The terminal UI

The gateway console, in a terminal: every page of the web console, for a
serial line, an SSH session, a Pi's own screen, or the USB cable on a board
that can be a USB device.

```
parkeze-tui
```

## Where it runs

| | How you get there | Sign-in |
|---|---|---|
| Serial console | it is already there | the web console's |
| SSH as root | `parkeze-tui` at the shell | none: you are root |
| SSH as `parkeze` | `ssh parkeze@<gateway>`; Ctrl-C disconnects | the web console's |
| parkeze.net **Console** | a gateway's page, as an organization's admin | parkeze.net's; no shell |
| HDMI (Pi) | it is already there, when a screen was attached at boot | the web console's |
| USB serial (Pi 4, Pi 5) | the port that appears beside the USB network | the web console's |

From a shell there is nothing to sign in to — root can already do everything
the console can. On a port the TUI *is* the program, so it asks for what the
web console asks for: the local password while that is allowed, and the
offline recovery signature on an adopted gateway. A screen and a keyboard on a
gateway in a car park are physical access, and [`auth.md`](auth.md) is plain
that physical access proves nothing. A port signs itself out after fifteen
minutes without a key.

### From parkeze.net

An organization's admin on parkeze.net gets this console on their gateway, not
a shell: a root shell on ParkezeOS is a copy of ParkezeOS. parkeze.net opens an
SSH session whose only command is

```
parkeze-tui --remote
```

and, on a gateway that trusts its certificate authority, names that command
as the certificate's `force-command`, so sshd runs nothing else whatever the
client asks for. In this mode there is no sign-in — the person signed in to
parkeze.net, which records who opened the session — and no `!`. Changes are
journalled `by: parkeze.net`; `q` ends the session. Parkeze staff still get a
shell from parkeze.net.

### Sign in with Parkeze, without a browser

The web console's handoff lands a token on a browser origin, and a terminal
has none. So the terminal does it the way a television signs in to a
streaming service:

1. The gateway starts a sign-in with parkeze.net and shows a code and a QR of
   `net.parkeze.com/gateway-access#signin=<code>`.
2. Somebody signed in to parkeze.net — on a phone, usually — opens it, sees
   which gateway is asking, and approves or refuses. That needs net-admin, as
   the browser handoff does, and is audited against them.
3. The gateway polls, and collects the same fleet-signed token the browser
   would have got, marked `aud: terminal` with the code in it. `auth.uc`
   accepts that token only for the sign-in it started, and the web console
   accepts no token carrying an audience — so neither opens the other door.

Only the gateway can start or collect its own sign-in: both calls carry its
claim secret, as `/report` does. The code on the screen is an address, not a
key; seeing it lets you ask somebody to approve, and collect nothing. No token
is stored on parkeze.net while a sign-in waits — it is minted when the gateway
collects it. Online only; offline, recovery is the way in. A QR that will not
scan: the code typed at `net.parkeze.com/gateway-access` works the same.

The server half is `net-api/plugins/gateway_ops/console_signin.py` in
parkeze.net; the gateway half is `parkeze-console-signin` and `auth.uc`.

## Parity, and how it is kept

Same pages, same order, same labels, notices and badge words — the React page
is the reference, and each file in `tui/pages/` is that page restated in
blocks. Underneath they call the same code:

- **Reads** go to the console's `lib/` modules directly, the way
  `api/index.uc`'s GET routes do.
- **Changes** go through `lib/actions.uc`, which the API's POST routes call
  too. Validation and audit records live there and nowhere else, so an action
  taken at a keyboard is checked and journalled exactly as one taken in a
  browser.

A firmware upgrade is the one control that differs: a terminal has no file
picker, so the image is a path on the gateway — the SD card, or `/tmp` after
copying it over SSH — and goes through the same `fwtool` board check,
`sysupgrade -T`, signature verification and journal as an upload. A file
somebody pointed at is left in place if it is refused.

Adding a page to the console means adding it here as well. `tui/app.uc` has
the sidebar in `nav.ts`'s order.

## Keys

↑ ↓ (or j k, Tab) move, Enter selects, Esc goes back to the menu, r refreshes,
q quits — or signs out, on a port. A field is edited in place: Enter saves,
Esc cancels. PgUp and PgDn scroll a long page. Ctrl-L redraws, and asks a
serial terminal its size again.

## The shell

Only for Parkeze: a TUI started from a root shell, or a session parkeze.net
signed as staff's ([`auth.md`](auth.md), "Who gets root"). Not for the local
password, an organization admin's Parkeze or recovery sign-in, or a remote
session; a development image lets any signed-in session through. There, `!`
drops to a login shell on the same terminal; `exit` or Ctrl-D comes back
to the console, redrawn and refreshed. The TUI steps aside rather than running
beside the shell, so it is the ordinary shell — the banner, job control,
Ctrl-C — and works the same on a serial line, over SSH, on HDMI and on the USB
serial port.

On a port each one is journalled as `console.shell`. An idle shell on a port
logs itself out after fifteen minutes, where the shell supports `TMOUT`.

## Terminals

It asks rather than assumes. A serial line has no window size, so the TUI
parks the cursor in the far corner and asks where it ended up; it draws a box
character and asks how far the cursor moved, to learn whether the far end is
UTF-8. Without UTF-8 it draws in ASCII. Without colour it still works: a status
is a word, and focus is reverse video.

A RAK's console is 57600 baud — about 5.7KB a second, where one full 80x24
frame in colour is several KB. So only lines that changed are sent, and a page
that is not live blocks on the keyboard instead of redrawing on a timer. Live
pages stop refreshing after fifteen minutes without a key.

`PARKEZE_ASCII=1` and `PARKEZE_COLOR=0|16|256|24` override what it detects.

## The mark

The logo is drawn by `parkeze-logo` from `/usr/share/parkeze/logo.txt`: eight
rows of half-block cells, sixteen pixels high. The login banner draws it beside
the wordmark, as does the TUI's sign-in screen, and Overview on a screen tall
enough to spare the rows.

`scripts/render-logo.py` makes the grid from `console/public/logo.png`. The
shape is drawn by hand there — at sixteen pixels a downsample keeps the pin and
loses the Z — and only the colours come from the image. On the Pi's framebuffer
console the kernel folds 256-colour codes to its own sixteen by thresholding,
which turns the whole mark cyan, so on that console the mark picks its own.

## The ucode it runs on

OpenWrt 24.10.0 pins ucode 2024-07-22. Three things about it shaped this code,
and will bite anything else that reads a terminal:

- **A timed-out read is sticky.** `file.read(n)` is a bare `fread()`; under
  musl the EOF flag it sets is never cleared, so every later read on that
  handle returns nothing. Input is a handle on the tty that is closed and
  reopened at EOF — the one moment its stdio buffer is known to be empty.
- **A closure in a loop sees the last value.** `for (let x in list)` has one
  binding for the whole loop. Copy the variable into a `const` inside the body,
  or use `map()`.
- **`7 / 2` is `3`.** Integer division stays integer; multiply by `1.0` first.

There is no `ioctl()` either, so raw mode and the window size go through
`stty`. OpenWrt's busybox has none, which is why the package depends on
`coreutils-stty`.

## Running it on a Mac

```bash
UCODE=/tmp/ucode/build/ucode scripts/run-tui.sh
```

Runs the real pages against canned gateway state from
`scripts/tui-fixture/api.uc`. Add `--console` for the sign-in screens; the
fixture's password `wrong` fails and `initial` forces a password change. `--remote`
is the session parkeze.net opens.
