# Speed tests

`pulzr-speedtest`, on boards with the `speedtest` feature (the Opal and the
Pis: librespeed-cli is a 10 MB Go binary, more than a RAK's flash has to
spare). Network > Speed Test in the console.

## Two tests, to compare

| | |
|---|---|
| Direct | librespeed-cli against the nearest LibreSpeed public server, once per free uplink, bound to that uplink's device (`--interface`), so a test cannot fall through to another link mid-run |
| Tunnel | the cloud sending to and taking from this gateway over WireGuard, the path the console, SSH and management take through Pulzar Cloud |

A fast line with a slow tunnel says the tunnel is the problem. The tunnel
test is asked for over the report's channel (`pulzr-claim tunnel-test`,
proved by the claim secret); the cloud runs one at a time across Pulzar Cloud and
answers `busy` otherwise, and the gateway tries again a minute or two later.
the cloud measures against two endpoints the console answers only on the
tunnel port, only to the hub (`/api/speedtest/tunnel/source` and `sink`).

There is no speed test server of ours. The LibreSpeed list is public servers
run by their sponsors, the nearest by ping each time, tried over plain HTTP
first: on the Opal TLS is the limit, not the line (one HTTPS download from
a cloud host ran at 11.7 Mb/s where plain HTTP ran at 48). HTTPS is the fallback
for a server that does not answer HTTP, and each result says which it was.

## Never cellular

Only wired and WiFi uplinks are tested. A WiFi network still at its sign-in
page, an uplink tracking has seen carry nothing, and the tunnel while it rides
cellular are skipped. A gateway whose only uplink is cellular never runs one.

## When

Daily by default, at this gateway's own minute between 01:00 and 05:00 by its
clock and zone (from its EUI, so a fleet does not test at once), or weekly, or
off. About ten seconds each way per uplink: on a 100 Mb/s line roughly 200 MB
a run. `pulzr-speedtest schedule off|daily|weekly`.

## Where results go

`/etc/pulzr/speedtest/history.json`, the last 120, kept across upgrades.
The latest of each test on each uplink rides on every report (`speedtest`),
and a run reports at once. The MQTT agent's `speedtest` op answers with the
last 30, short, under its 8 KB limit. Pulzar Cloud shows both on the gateway's
Backhaul.

```
pulzr-speedtest status | latest | brief
pulzr-speedtest start               run now, in the background
pulzr-speedtest schedule daily
```
