# Setup mode on a real gateway

What `scripts/test-setup-mode.sh` cannot say: that the kernel sends the events,
that procd runs the link, that a radio does what uci says, and that a person can
see the result. Run this once per board. Record the board, the PulzrOS version
and pass or fail for each step. An unknown unit is not flashed: check the board
and the recovery route in `docs/flashing.md` first.

Every step starts adopted, on PulzrOS 0.3.13 or later, with a laptop on a LAN port
or the WAN side, and `logread -f | grep -E 'button|ap'` open over SSH when the
step keeps a network up.

## The console on a LAN port

1. Unplug every uplink. Plug a laptop into a LAN port. It gets a lease on the
   device LAN. Open `https://<gateway LAN address>`. Expect the sign-in page.
2. Sign-in with the platform, the laptop on its own phone hotspot or other
   internet: expect the browser to go to the platform and return signed in, with
   an org admin account. A member, or an account of another org, is refused.
3. Same page with no internet on the laptop: Recovery. Copy the challenge to the
   gateway's page in the platform from a phone, type the signed code back. Expect
   a session of 30 minutes.
4. Local password, adopted: refused unless a root shell opened it
   (`pulzr-local-access`).
5. SSH on the LAN port: refused. 8080 on the LAN port: refused.
6. Backhaul > WiFi: scan, join a network with the wrong password. Expect the
   failure on the page. Join with the right one. Expect the tunnel back within
   a few minutes, and the gateway online in the platform.

## Four presses

Before step 1, read Setup Network on the gateway's page in the platform while
the gateway is online, and note the name and passphrase.

1. Refusal, wired: uplink on `wan` working. Four presses. Expect every light to
   flash fast (red breathing on RGB) for 6 seconds, no new SSID, and
   `reset button: wired works` or `tunnel works` in the log.
2. Refusal, second wired uplink: make `lan1` an uplink on Ports, cable on it only.
   Four presses. Same result. Set the port back.
3. Refusal, WiFi: station joined to a working network, no cable. Same result.
4. Refusal, cellular: SIM or USB modem working, no cable, no WiFi. Same result.
5. Raised: nothing connected, and the old WiFi out of range or switched off. Four
   presses. Within 15 seconds `Pulzar-<six hex>` is on the air and the light shows
   setup. Join with the passphrase noted above; expect an address and no route.
   Open `https://192.168.62.1` and sign in with Recovery. Join a working network
   on Backhaul > WiFi. Expect the AP to come down and the light to return to its
   normal code within a minute or two.
6. Window: raise it again, join nothing, wait 30 minutes. Expect it to come down
   and the old station to be enabled again.
7. Power cut with the AP up: expect the old station back on after boot.

## The button is not a reset

1. One press: status code, no reboot. Three and five presses: nothing. A pause of
   more than 2.5 seconds restarts the count.
2. Hold for 5 seconds, release: nothing; the config survives.
3. Four presses, then hold: all lights on at 10 seconds. Do this one only on a
   unit you intend to reset, and expect it released from the platform afterwards.

## The Opal's light

Compiled, not yet seen on a unit: branch `et6326-leds` of `openwrt-gl-sft1200` and
the PulzrOS branch that points at its build.

1. Only on a GL-SFT1200 with a known recovery route (GL's U-Boot web recovery).
   Flash the branch's image.
2. `ls /sys/class/leds`. Expect `blue:status`, `white:status`, `et6326:channel2`.
   `dmesg | grep -iE 'i2c|ktd|et6326'`. A probe error here stops the test; report
   it, nothing else below can pass.
3. Run the channel test in that repo's README and write down the colour of each.
4. `pulzr-led status setup`: one short flash a second. `pulzr-led status alert`:
   fast, around 5 Hz, not a slow 16-second cycle. Time them on a phone.
5. Run Four presses above; both outcomes must be visible across a room.
6. Then: correct the names, remove channel 2, merge, push to main (which
   publishes the release), and map the LED in
   `boards/gl-sft1200/board.conf`.

## What each board shows

| Board | Raised | Refused |
|---|---|---|
| RAK7268CV2 | top light breathes green | top light breathes red, 6 s |
| RAK7289CV2 | LoRa lights flash once a second | LoRa lights flash fast, 6 s |
| Raspberry Pi | ACT flashes once a second | ACT and PWR flash fast, 6 s |
| GL-SFT1200 | nothing until the light above is validated; the SSID appears | nothing; `logread` only |
