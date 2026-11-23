---
title: "Speed tests"
description: "pulzr-speedtest, on boards with the speedtest feature (the Opal and the Pis: librespeed-cli is a 10 MB Go binary, more than a RAK's flash has to spare)."
---

`pulzr-speedtest`, on boards with the `speedtest` feature (the Opal and the
Pis: librespeed-cli is a 10 MB Go binary, more than a RAK's flash has to
spare). Network > Speed Test in the console runs and schedules them; each row
of the Backhaul page tests that one connection.

## Two tests, to compare

| | |
|---|---|
| Direct | librespeed-cli against the nearest LibreSpeed public server, once per free uplink, bound to that uplink's device (`--interface`), so a test cannot fall through to another link mid-run |
| Tunnel | the cloud sending to and taking from this gateway over WireGuard, the path the console, SSH and management take through Pulzr Cloud |

A fast line with a slow tunnel says the tunnel is the problem. The tunnel
test is asked for over the report's channel (`pulzr-claim tunnel-test`,
proved by the claim secret); the cloud runs one at a time across Pulzr Cloud and
answers `busy` otherwise, and the gateway tries again a minute or two later.
the cloud measures against two endpoints the console answers only on the
tunnel port, only to the hub (`/api/speedtest/tunnel/source` and `sink`).

There is no speed test server of ours. The LibreSpeed list is public servers
run by their sponsors, the nearest by ping each time, tried over plain HTTP
first: on the Opal TLS is the limit, not the line (one HTTPS download from
a cloud host ran at 11.7 Mb/s where plain HTTP ran at 48). HTTPS is the fallback
for a server that does not answer HTTP, and each result says which it was.

## Never cellular on its own

A run of every uplink, scheduled or from Network > Speed Test, tests only
wired and WiFi uplinks. A WiFi network still at its sign-in page, an uplink
tracking has seen carry nothing, and the tunnel while it rides cellular are
skipped. A gateway whose only uplink is cellular never runs one by itself.

## One connection

`pulzr-speedtest start <iface>` tests that uplink alone, whatever its place in
the failover order: the speed test button on a Backhaul row. curl and
librespeed-cli bind to the uplink's device, and the kernel answers a bound
socket from that device's own default route, which netifd keeps at the
uplink's metric, so a standby cable or the SIM behind a working cable is
tested over itself and nothing about which uplink carries traffic changes. No
tunnel test: the tunnel is one path, whichever uplink it rides. An uplink on a
WiFi sign-in page is refused.

| Metered uplink (`wwan`, `usbwan`) | |
|---|---|
| Runs | only with `metered` after its name: the console sends it once somebody has seen the estimate and pressed Run |
| Length | 5 s each way, not the configured duration |
| Estimate | `status`'s `metered`: the last test on it scaled to 5 s, or 50 down and 20 up Mb/s without one, about 44 MB |
| Recorded | `metered: true`, with the bytes each way |

`scripts/test-speedtest.sh` checks the device each test binds to, that no
route is touched, the refusal without the confirm and that the nightly run
still leaves cellular alone, in CI.

## When

Daily by default, at this gateway's own minute between 01:00 and 05:00 by its
clock and zone (from its EUI, so a fleet does not test at once), or weekly, or
off. About ten seconds each way per uplink: on a 100 Mb/s line roughly 200 MB
a run. `pulzr-speedtest schedule off|daily|weekly`.

## Where results go

`/etc/pulzr/speedtest/history.json`, the last 120, kept across upgrades.
The latest of each test on each uplink rides on every report (`speedtest`),
and a run reports at once. The MQTT agent's `speedtest` op answers with the
last 30, short, under its 8 KB limit. Pulzr Cloud shows both on the gateway's
Backhaul.

```
pulzr-speedtest status | latest | brief
pulzr-speedtest start               run now, in the background
pulzr-speedtest start wan_lan2      that uplink alone
pulzr-speedtest start wwan metered  the SIM, its cost confirmed
pulzr-speedtest schedule daily
```
