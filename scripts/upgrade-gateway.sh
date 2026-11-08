#!/usr/bin/env bash
#
# Install a PulzrOS image on an adopted gateway from the command line, through
# Pulzr Net, keeping its settings.
#
#   scripts/upgrade-gateway.sh [--check] [--force] <gateway> <version | image> [manifest]
#
#   <gateway>   its gateway id or its name in Pulzr Net
#   <version>   a release, as 0.3.6 or v0.3.6: that board's image and its
#               signature are fetched from the release and checked against
#               the release's sha256sums.txt
#   <image>     a local image file instead; its signature is <image>.parkeze.json
#               when that exists, or the [manifest] given
#   --check     stage and check the image on the gateway, then remove it and
#               stop, without installing anything
#   --low-memory
#               stage in RAM with 4MB left over instead of 16MB, for a gateway
#               with no card whose RAM cannot otherwise hold its own image
#   --force     install even when the gateway already reports that version, or
#               when the image has no signature
#
# Needs kubectl access to the cluster (namespace parkeze-net, or
# PULZR_NAMESPACE) and, for a version, the gh CLI signed in to GitHub.
#
# ── WHAT IT DOES ────────────────────────────────────────────────────────────
#
# What the console's firmware page does (lib/firmware.uc), from this Mac: the
# gateway is reached over its management tunnel from the gateway-link pod, the
# one place that holds the route and the SSH credentials, so this works the
# same for a gateway on a Wi-Fi uplink in a field as for one on the bench.
#
#   1. the image is copied to the gateway's card when it has one, as the
#      console does, and otherwise to /tmp, after checking there is room;
#   2. its sha256 is compared on the gateway, `sysupgrade -T` checks it is an
#      image for that board, and `parkeze-firmware verify` checks its
#      signature;
#   3. `parkeze-firmware pending` records the upgrade, then sysupgrade runs,
#      keeping settings;
#   4. this waits for the gateway's first report to Pulzr Net after the
#      upgrade and prints the version in it.
#
# Any check that fails removes the staged image and installs nothing.

set -euo pipefail

NS="${PULZR_NAMESPACE:-parkeze-net}"
REPO="${PULZR_RELEASE_REPO:-pulzar-net/PulzrOS}"
POD_DIR=/tmp/pulzr-upgrade

check_only=0
force=0
headroom_mb=16
while [ $# -gt 0 ]; do
    case "$1" in
        --check) check_only=1; shift ;;
        --force) force=1; shift ;;
        --low-memory) headroom_mb=4; shift ;;
        -h|--help) sed -n '3,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        --) shift; break ;;
        -*) echo "unknown option: $1" >&2; exit 2 ;;
        *) break ;;
    esac
done
[ $# -ge 2 ] || { sed -n '3,22p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
gateway_arg="$1"; image_arg="$2"; manifest_arg="${3:-}"

die() { echo "error: $*" >&2; exit 1; }
say() { echo "== $*"; }

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

# ── the gateway ─────────────────────────────────────────────────────────────

# Looked up by id or by exact name. The argument reaches psql as a variable,
# never as part of the SQL text.
cat > "${work}/lookup.sql" <<'SQL'
select g.gateway_id, g.name, g.model,
       coalesce(g.metadata->>'osVersion', ''),
       coalesce(g.metadata->>'sshHostKey', ''),
       coalesce(split_part(p.address::text, '/', 1), ''),
       coalesce(g.mgmt_ssh_port, 22)
  from gateways g
  left join gateway_wireguard_peers p using (gateway_id)
 where g.gateway_id = :'q' or g.name = :'q';
SQL
rows="$(kubectl -n "${NS}" exec -i net-db-0 -- \
    sh -c 'psql -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-postgres}" -At -F "|" -v q="$1"' \
    sh "${gateway_arg}" < "${work}/lookup.sql")" || die "could not query Pulzr Net's database"

case "$(printf '%s\n' "${rows}" | grep -c . || true)" in
    0) die "no gateway with id or name '${gateway_arg}'" ;;
    1) ;;
    *) echo "more than one gateway matches '${gateway_arg}':" >&2
       printf '%s\n' "${rows}" | cut -d'|' -f1,2 | sed 's/|/  /; s/^/  /' >&2
       exit 1 ;;
esac
IFS='|' read -r gw_id gw_name board version_now host_key tunnel_ip ssh_port <<EOF
${rows}
EOF
[ -n "${tunnel_ip}" ] || die "${gw_name} (${gw_id}) has no management tunnel address"
[ -n "${board}" ] || die "${gw_name} (${gw_id}) has no board recorded"
say "${gw_name} (${gw_id}): ${board}, PulzrOS ${version_now:-unknown}, tunnel ${tunnel_ip}"

# ── the image ───────────────────────────────────────────────────────────────

if [ -f "${image_arg}" ]; then
    image="${image_arg}"
    manifest="${manifest_arg:-${image}.parkeze.json}"
    [ -f "${manifest}" ] || manifest=""
    target_version=""
else
    target_version="${image_arg#v}"
    printf '%s' "${target_version}" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
        || die "'${image_arg}' is neither a file nor a version such as 0.3.6"
    if [ "${version_now}" = "${target_version}" ] && [ "${force}" = 0 ]; then
        say "${gw_name} already reports ${target_version}; nothing to do (--force to install it again)"
        exit 0
    fi

    # A Pi upgrades from its -sysupgrade image; a router's one image is both.
    tag="v${target_version}"
    gh release download "${tag}" -R "${REPO}" -p sha256sums.txt -D "${work}" \
        || die "could not fetch ${tag}'s sha256sums.txt from ${REPO}"
    asset=""
    for name in "ParkezeOS-${target_version}-${board}-sysupgrade.img.gz" \
                "ParkezeOS-${target_version}-${board}.bin"; do
        if grep -q "[ /*]${name}\$" "${work}/sha256sums.txt"; then asset="${name}"; break; fi
    done
    [ -n "${asset}" ] || die "${tag} has no upgrade image for ${board}"
    say "fetching ${asset}"
    gh release download "${tag}" -R "${REPO}" -p "${asset}" -D "${work}"
    gh release download "${tag}" -R "${REPO}" -p "${asset}.parkeze.json" -D "${work}" 2>/dev/null || true

    image="${work}/${asset}"
    manifest="${work}/${asset}.parkeze.json"
    [ -f "${manifest}" ] || manifest=""
    want="$(grep "[ /*]${asset}\$" "${work}/sha256sums.txt" | awk '{ print $1 }')"
    got="$(shasum -a 256 "${image}" | awk '{ print $1 }')"
    [ "${want}" = "${got}" ] || die "${asset} does not match ${tag}'s sha256sums.txt"
fi

if [ -z "${manifest}" ] && [ "${force}" = 0 ]; then
    die "no signature for $(basename "${image}") (--force to install an unsigned image)"
fi
sha="$(shasum -a 256 "${image}" | awk '{ print $1 }')"
size="$(wc -c < "${image}" | tr -d ' ')"
say "image $(basename "${image}"): ${size} bytes, sha256 ${sha}, $([ -n "${manifest}" ] && echo signed || echo UNSIGNED)"

# ── on the gateway, from gateway-link ───────────────────────────────────────

cat > "${work}/run.py" <<'PY'
# Runs in the gateway-link pod. Modes: stage IMAGE SHA HEADROOM_MB [MANIFEST],
# install ISSUER, clean. Prints what happened; exits non-zero on any failure.
# The path the image was staged at is kept beside this file for the later modes.
import os
import sys

sys.path.insert(0, '/app')
import ssh  # noqa: E402  gateway-link's own SSH client

GW = {'mgmt_host': os.environ['GW_HOST'],
      'mgmt_ssh_port': int(os.environ.get('GW_PORT') or 22),
      'ssh_host_key': os.environ.get('GW_HOSTKEY') or None}
MAN = '/tmp/parkeze-firmware.manifest'
STAGED = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'staged')
IMG = open(STAGED).read().strip() if os.path.exists(STAGED) else ''


def run(command, stdin=b'', timeout=120):
    out, err, rc, _ = ssh.execute(GW, command, stdin=stdin, timeout=timeout)
    return out.decode(errors='replace').strip(), err.decode(errors='replace').strip(), rc


def refuse(why):
    run('rm -f %s %s' % (IMG or '/nonexistent', MAN))
    print(why)
    sys.exit(1)


mode = sys.argv[1]
if mode == 'stage':
    path, want, headroom = sys.argv[2], sys.argv[3], int(sys.argv[4])
    manifest = sys.argv[5] if len(sys.argv) > 5 else ''
    with open(path, 'rb') as f:
        image = f.read()
    # The card first, as the console stages (lib/firmware.uc): RAM is what
    # the rest of the gateway runs in.
    out, _, _ = run('[ "$(uci -q get parkeze.storage.present)" = 1 ] && '
                    '[ "$(uci -q get parkeze.storage.writable)" = 1 ] && '
                    'd="$(uci -q get parkeze.storage.mount)/parkeze/firmware" && '
                    'mkdir -p "$d" && echo "$d" && df -k "$d" | awk \'NR == 2 { print $4 }\'')
    card = out.split()
    if len(card) == 2 and int(card[1]) * 1024 > len(image):
        IMG = card[0] + '/parkeze-firmware.img'
        print('staging on the card, %s' % card[0])
    else:
        out, _, _ = run("awk '/^MemAvailable/ { print $2 }' /proc/meminfo")
        avail = int(out or 0) * 1024
        need = len(image) + headroom * 1024 * 1024
        if avail < need:
            print('not enough memory on the gateway and no card: %d MiB free, %d MiB '
                  'needed with %d MiB left over' % (avail >> 20, need >> 20, headroom))
            sys.exit(1)
        IMG = '/tmp/parkeze-firmware.img'
        print('staging in RAM: %d MiB free, %d MiB left over after the image'
              % (avail >> 20, (avail - len(image)) >> 20))
    with open(STAGED, 'w') as f:
        f.write(IMG)
    _, err, rc = run('cat > %s' % IMG, stdin=image, timeout=900)
    if rc != 0:
        refuse('copying the image failed: %s' % err)
    out, _, _ = run('sha256sum %s' % IMG)
    if out.split()[:1] != [want]:
        refuse('the copy on the gateway does not match (%s)' % out)
    print('copied, sha256 matches')
    out, err, rc = run('sysupgrade -T %s 2>&1' % IMG, timeout=180)
    if rc != 0:
        refuse('not an image for this gateway: %s' % (out or err))
    print('sysupgrade -T: ok')
    if manifest:
        with open(manifest, 'rb') as f:
            run('cat > %s' % MAN, stdin=f.read())
        out, err, rc = run('parkeze-firmware verify %s %s 2>&1' % (IMG, MAN))
        run('rm -f %s' % MAN)
        if rc != 0:
            refuse('signature: %s' % (out or err or 'does not verify'))
        print('signature: verified')
elif mode == 'install':
    who = ''.join(c for c in sys.argv[2] if c.isalnum() or c in '._@-') or 'cli'
    out, err, rc = run(
        'parkeze-firmware pending %s %s && '
        '{ (sleep 3; sysupgrade %s) >/dev/null 2>&1 </dev/null & } && echo started'
        % (IMG, who, IMG), timeout=60)
    if rc != 0 or 'started' not in out:
        refuse('starting the upgrade failed: %s %s' % (out, err))
    print('upgrade started, settings kept')
elif mode == 'clean':
    run('rm -f %s %s' % (IMG, MAN))
PY

pod_exec() { # stdin is passed through
    kubectl -n "${NS}" exec -i deploy/gateway-link -c gateway-link -- \
        env GW_HOST="${tunnel_ip}" GW_PORT="${ssh_port}" GW_HOSTKEY="${host_key}" "$@"
}
pod_put() { # local-file pod-path
    kubectl -n "${NS}" exec -i deploy/gateway-link -c gateway-link -- \
        sh -c 'cat > "$1"' sh "$2" < "$1"
}
remote() { pod_exec python "${POD_DIR}/run.py" "$@"; }

kubectl -n "${NS}" exec deploy/gateway-link -c gateway-link -- mkdir -p "${POD_DIR}"
trap 'kubectl -n "${NS}" exec deploy/gateway-link -c gateway-link -- rm -rf "${POD_DIR}" >/dev/null 2>&1 || true; rm -rf "${work}"' EXIT
pod_put "${work}/run.py" "${POD_DIR}/run.py"
pod_put "${image}" "${POD_DIR}/image"
if [ -n "${manifest}" ]; then
    pod_put "${manifest}" "${POD_DIR}/manifest"
    pod_manifest="${POD_DIR}/manifest"
else
    pod_manifest=""
fi

say "staging on ${gw_name}"
remote stage "${POD_DIR}/image" "${sha}" "${headroom_mb}" ${pod_manifest:+"${pod_manifest}"} \
    || die "the image was refused; nothing was installed"

if [ "${check_only}" = 1 ]; then
    remote clean || true
    say "check passed; staged image removed, nothing installed (--check)"
    exit 0
fi

issuer="$(git config user.email 2>/dev/null || echo "${USER:-cli}")"
started="$(date -u +%s)"
remote install "${issuer}" || die "the upgrade did not start"

# Back means a report newer than the start, which the gateway sends once it
# has booted and brought its tunnel back. That needs nothing from it over SSH,
# so a host key that changed in the upgrade cannot make it look gone.
report() {
    kubectl -n "${NS}" exec -i net-db-0 -- \
        sh -c 'psql -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-postgres}" -At -F "|" -v id="$1"' \
        sh "${gw_id}" <<'SQL'
select coalesce(metadata->>'osVersion', ''),
       coalesce(extract(epoch from (metadata->>'reportedAt')::timestamptz)::bigint, 0)
  from gateways where gateway_id = :'id';
SQL
}

# sysupgrade takes a few minutes on flash; a gateway on Wi-Fi then has to
# rejoin its network and bring the tunnel back before it reports.
say "waiting for ${gw_name} to come back (up to 15 minutes)"
deadline=$(( started + 15 * 60 ))
while [ "$(date -u +%s)" -lt "${deadline}" ]; do
    sleep 20
    IFS='|' read -r now reported <<EOF
$(report 2>/dev/null || true)
EOF
    if [ "${reported:-0}" -gt "${started}" ]; then
        say "${gw_name} is back and reports PulzrOS ${now:-unknown}"
        if [ -n "${target_version}" ] && [ "${now}" != "${target_version}" ]; then
            die "it reports ${now}, not ${target_version}"
        fi
        exit 0
    fi
done
die "${gw_name} has not reported within 15 minutes; check it in Pulzr Net"
