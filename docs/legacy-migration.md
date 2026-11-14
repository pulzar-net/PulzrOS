# Upgrading from ParkezeOS

PulzarOS is the earlier ParkezeOS under a new name, and its version numbers
continue from it. A gateway running ParkezeOS upgrades with `sysupgrade`
keeping settings, and comes up as the same gateway: same identity, same claim,
same tunnel key, same broker, still adopted. Nothing is re-adopted and nobody
visits it.

## What carries over

Everything a gateway needs to be itself, byte for byte:

| Old path | New path | What it is |
|---|---|---|
| `/etc/config/parkeze` | `/etc/config/pulzr` | identity, adoption state, broker credentials and host, LoRaWAN, LAN clients, uplinks |
| `/etc/parkeze/claim/` | `/etc/pulzr/claim/` | the claim identity and secret |
| `/etc/parkeze/console/` | `/etc/pulzr/console/` | console username and password hash, TLS certificate and key, audit log |
| `/etc/parkeze/wireguard/` | `/etc/pulzr/wireguard/` | the WireGuard private key and the tunnel's endpoint |
| `/etc/parkeze/recovery.pub` | `/etc/pulzr/recovery.pub` | the recovery anchor the gateway was adopted with |
| `/etc/parkeze/site-keys` | `/etc/pulzr/site-keys` | keys a technician provisioned on this unit |
| `/etc/parkeze/upgrade/` | `/etc/pulzr/upgrade/` | the upgrade journal, which names the image to roll back to |
| `/etc/parkeze/speedtest/` | `/etc/pulzr/speedtest/` | speed test history |
| `/etc/parkeze/ap/`, `/etc/parkeze/lan/` | `/etc/pulzr/ap/`, `/etc/pulzr/lan/` | the setup AP secret; LAN device history and forwards |
| `<card>/parkeze/` | `<card>/pulzr/` | firmware stash, backups and buffered uplinks on the SD card (the old name stays as a link) |

SSH host keys (`/etc/ssh`, `/etc/dropbear`), the SSH CA, the fleet and recovery
keys, and the firmware signing key are not touched or renamed in value. The
broker and tunnel hosts a gateway was given at adoption (`mqtt.parkeze.com`,
`wg.net.parkeze.com`) are stored as given and are not rewritten.

`board.conf` and `firmware.pub` describe the image and always come from the new
one.

## How

`01-pulzr-migrate` is the first `uci-defaults` script of the new image. It runs
`pulzr-legacy forward`, which copies the old paths to the new ones. The old copies
stay, so that a rollback has something to find.

`pulzr-legacy back` is run by `pulzr-firmware` just before any upgrade or
rollback it performs and writes the current state to the old paths. The keep list
(`/lib/upgrade/keep.d/pulzr`) names both sets, so a gateway rolled back to the
last ParkezeOS image restores everything where that image looks for it.

Which copy is current is decided by one marker, `/etc/parkeze/.synced-from-pulzr`:
present means the new paths are current; absent means the old ones are. ParkezeOS
does not keep the marker across its own upgrades, so a gateway that went back to
ParkezeOS, changed something and was upgraded again picks up the changes.

An upgrade done by hand with a bare `sysupgrade`, without `pulzr-firmware
pending`, does not refresh the old copies; a rollback after that restores the
state of the last refresh.

`scripts/test-legacy.sh` builds a fake ParkezeOS root, runs the migration,
checks every file and value, then checks the rollback.

## What changes visibly

- The hostname and the setup AP name become `pulzr-<serial>` and `Pulzar-<mac>`.
  The gateway also answers `parkeze.local` and `parkeze-<serial>.local` over
  mDNS for as long as the aliases are kept.
- `ssh parkeze@<gateway>` still works: it is the same console account as
  `ssh pulzr@<gateway>`.
- A stored console username (`parkeze`) is kept; new gateways use `pulzr`.

## Names kept on purpose

These stay as ParkezeOS spelled them because something outside the gateway, or
the previous image after a rollback, reads them:

- the MQTT management topic root `parkeze/gateway/<eui>/...` and the LAN client
  policy value `parkeze`, which the cloud sends and reads;
- the keys `parkeze_version` and `parkeze_build` in the gateway facts;
- the wireless section ids `parkeze_sta` and `parkeze_ap`, so saved Wi-Fi
  survives an upgrade and a rollback;
- the endpoints `net.parkeze.com`, `mqtt.parkeze.com` and `wg.net.parkeze.com`,
  where a gateway's own configuration names them.

The aliases and shims (`parkeze.local`, the `parkeze` SSH account,
`/usr/libexec/parkeze-tui-console`, the old-path copies) are meant to go once no
gateway is left on a ParkezeOS image; removing them is a change to
`pulzr-legacy`, the keep list and the files above.
