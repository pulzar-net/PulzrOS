---
title: "Logging"
description: "An adopted gateway sends its system log to Pulzar Cloud, where its page keeps it for 90 days."
---

An adopted gateway sends its system log to Pulzar Cloud, where its page
keeps it for 90 days beside what was done to it: firmware updates, commands,
outages and settings changes. The log on the gateway is in RAM and gone at
the next boot; this is the copy that is not.

## What is sent

`pulzr-logship` (in `pulzr-adopt`) follows `logread -t` and sends the lines at
`pulzr.logship.level` and worse, `notice` by default: what daemons say when
something changes or fails. `info` and `debug` stay on the gateway, where
`pulzr-logs` and the console's log read them. Each line goes with its
program and logd's own timestamp; a gateway with no clock yet (before NTP)
has its lines filed when they arrive.

```sh
uci set pulzr.logship.level=warning && uci commit pulzr   # less
uci set pulzr.logship.enabled=0 && uci commit pulzr       # none
```

## What it costs

| | |
|---|---|
| Lines | 60 at once, then 10 a minute (600 an hour); what is held back is counted in one line |
| Requests | one HTTPS POST a minute, every five on a metered uplink, sooner at 100 lines |
| Unreachable | batches are kept and sent with the next, up to 1,000 lines; then the oldest go, counted |

Pulzar Cloud holds every gateway to its own ceiling as well (1,200 lines an
hour), whatever firmware sends.

## How it is sent

`POST /api/v1/gateway-ops/syslog`, proved by the claim secret the way the
six-hourly report is (`pulzr-claim syslog`): no second credential and no
connection held open. The body is built in a root-only file curl reads, never
on a command line.

## Reading it

The gateway's page in Pulzar Cloud, **Log**, with its source, level and
search filters; every gateway's together under **Logs**, **Gateways**. Lines
from before a gateway ran `pulzr-logship`, and its `debug` lines, are read
from the gateway itself with **Read Now** there, or `pulzr-logs` on it.
