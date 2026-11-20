#!/usr/bin/env bash
#
# pulzr-addon against stand-ins for apk, curl, df, the health gate and the
# firmware journal, a JSON-backed uci, and a CDN in a directory.
#
#   UCODE=/path/to/ucode scripts/test-addon.sh
#
# The ucode needs its fs module beside it, as CI's build has. pulzr-addon
# runs as shipped except for ROOT, which points into a scratch directory, and
# the gate's timings, which are zero. Its addons.caps is generated from a
# scratch feed by the real scripts/addon-index.sh: pulzr-modbus's own addon
# file, and a second add-on that depends on it, which is how a deny is
# refused through a dependency.
#
# What an add-on install can get wrong is root code on a gateway nobody can
# reach, or Modbus on a gateway that denies it, and neither is found on a bench. So
# each refusal, the resume, the gate's revert and the restore after an
# upgrade run here.
#
# The stand-ins are written in single quotes on purpose: they expand when they
# run, not here.
# shellcheck disable=SC2016

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UCODE="${UCODE:-ucode}"
command -v "${UCODE}" >/dev/null 2>&1 || { echo "ucode not found; set UCODE=/path/to/ucode" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "jq not found" >&2; exit 2; }
UCODE="$(command -v "${UCODE}")"
MODULES="$(dirname "${UCODE}")/*.so"

T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT
R="${T}/root"
BIN="${T}/bin"
ARCH=aarch64_cortex-a53
VERSION=0.5.0
PKGVER=0.5.0-r1
BASE_URL=https://assets.example/pulzros/addons
export T R ARCH BASE_URL PULZR_ADDON_ROOT="${R}" SERVE="${T}/serve" UCI_JSON="${T}/uci.json"
mkdir -p "${BIN}"

sed -e "s#^const ROOT = '';#const ROOT = '${R}';#" \
    -e 's#^const SETTLE = 60, EVERY = 30, WINDOW = 300;#const SETTLE = 0, EVERY = 0, WINDOW = 0;#' \
    "${ROOT_DIR}/feed/pulzr-base/files/usr/sbin/pulzr-addon" > "${T}/pulzr-addon.uc"
if ! grep -q "^const ROOT = '${R}';" "${T}/pulzr-addon.uc" || ! grep -q '^const SETTLE = 0' "${T}/pulzr-addon.uc"; then
  echo "FAIL ROOT or the gate timings moved in pulzr-addon; update this script" >&2; exit 1
fi

# ── stand-ins ───────────────────────────────────────────────────────────────

stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "${BIN}/$1"; chmod +x "${BIN}/$1"; }

stub pulzr-addon "exec '${UCODE}' -R -L '${ROOT_DIR}/scripts/router-fixture/*.uc' -L '${MODULES}' '${T}/pulzr-addon.uc' \"\$@\""
stub logger 'exit 0'
stub pulzr-timeout 'shift; exec "$@"'
stub pulzr-claim 'echo "$*" >> "${T}/claim.log"'
stub pulzr-firmware '[ "$1" = status ] && printf "{\"state\":\"%s\"}\n" "$(cat "${T}/firmware")"'
# One verdict per call from ${T}/gate, the last one repeating.
stub pulzr-health-gate 'v="$(head -n1 "${T}/gate")"
[ "$(wc -l < "${T}/gate")" -gt 1 ] && { tail -n +2 "${T}/gate" > "${T}/gate.new"; mv "${T}/gate.new" "${T}/gate"; }
echo "${v}" >> "${T}/gate.log"
[ "${v}" = pass ]'
stub df 'echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
echo "/dev/root 1000000 1000 $(cat "${T}/free_kb") 1% /overlay"'
# The background job runs in the foreground here, so each case is in order.
stub start-stop-daemon 'while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do shift; done; shift; pulzr-addon "$@"; exit 0'

# Serves ${SERVE}/<path> for ${BASE_URL}/<path>. Resumes from the size of the
# -o file when given -C -, as curl does, and logs the offset it resumed at.
# A file named in ${T}/cut is cut off half way, once.
stub curl 'out="" url="" resume=0
while [ "$#" -gt 0 ]; do
  case "$1" in -o) out="$2"; shift ;; -C) resume=1; shift ;; --retry|--max-time) shift ;; -*) ;; *) url="$1" ;; esac
  shift
done
path="${url#"${BASE_URL}"/}"; src="${SERVE}/${path}"
[ -f "${src}" ] || { echo "curl: (22) The requested URL returned error: 404" >&2; exit 22; }
offset=0
[ "${resume}" = 1 ] && [ -f "${out}" ] && offset="$(wc -c < "${out}" | tr -d " ")"
echo "${path} resume=${resume} offset=${offset}" >> "${T}/curl.log"
if [ -f "${T}/cut" ] && [ "$(cat "${T}/cut")" = "${path##*/}" ]; then
  rm -f "${T}/cut"
  head -c "$(( $(wc -c < "${src}") / 2 ))" "${src}" > "${out}"
  echo "curl: (18) transfer closed with outstanding read data remaining" >&2; exit 18
fi
if [ "${offset}" -gt 0 ]; then tail -c +"$((offset + 1))" "${src}" >> "${out}"; else cat "${src}" > "${out}"; fi'

# apk-tools 3 as far as pulzr-addon uses it. The index is text, "name version
# depends...", and an .apk is a tar of the files it installs under ROOT. A
# pulzr-base= dependency must name ${T}/base_version, as a real one must name
# the pulzr-base installed.
stub apk 'echo "apk $*" >> "${T}/apk.log"
DB="${T}/apk/installed" FILES="${T}/apk/files"
index="" sim=0 args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --print-arch) echo "${ARCH}"; exit 0 ;;
    --repositories-file) shift ;;
    --repository) index="$2"; shift ;;
    --simulate) sim=1 ;;
    -*) ;;
    *) args+=("$1") ;;
  esac
  shift
done
installed() { awk -v n="$1" "\$1 == n { print \$2 }" "${DB}"; }
offered() { awk -v n="$1" "\$1 == n" "${index}"; }
case "${args[0]}" in
  list) v="$(installed "${args[1]}")"; [ -z "${v}" ] || echo "${args[1]}-${v} ${ARCH} {${args[1]}} (Apache-2.0) [installed]" ;;
  info) v="$(installed "${args[1]}")"; [ -n "${v}" ] || exit 1; echo "${args[1]}-${v} contains:"; cat "${FILES}/${args[1]}" ;;
  del)
    for n in "${args[@]:1}"; do
      while read -r f; do rm -f "${PULZR_ADDON_ROOT}/${f}"; done < "${FILES}/${n}"
      rm -f "${FILES}/${n}"; awk -v n="${n}" "\$1 != n" "${DB}" > "${DB}.new"; mv "${DB}.new" "${DB}"
    done ;;
  add)
    plan=()
    resolve() {
      local n="$1" line d p
      [ -z "$(installed "${n}")" ] || return 0
      for p in "${plan[@]}"; do [ "${p}" = "${n}" ] && return 0; done
      line="$(offered "${n}")"
      [ -n "${line}" ] || { printf "ERROR: unable to select packages:\n  %s (no such package)\n" "${n}"; exit 1; }
      for d in ${line#* * }; do
        case "${d}" in
          pulzr-base=*) [ "${d#pulzr-base=}" = "$(cat "${T}/base_version")" ] \
              || { printf "ERROR: unable to select packages:\n  %s:\n    breaks: %s\n" "${n}" "${d}"; exit 1; } ;;
          *) resolve "${d}" ;;
        esac
      done
      plan+=("${n}")
    }
    for n in "${args[@]:1}"; do resolve "${n}"; done
    i=0
    for n in "${plan[@]}"; do
      i=$((i + 1)); v="$(offered "${n}" | cut -d" " -f2)"
      echo "(${i}/${#plan[@]}) Installing ${n} (${v})"
      [ "${sim}" = 1 ] && continue
      f="$(dirname "${index}")/${n}-${v}.apk"
      [ -f "${f}" ] || { echo "ERROR: ${n}-${v}: No such file or directory"; exit 1; }
      tar -xf "${f}" -C "${PULZR_ADDON_ROOT}"
      tar -tf "${f}" | grep -v "/$" | sed "s#^\./##" > "${FILES}/${n}"
      echo "${n} ${v}" >> "${DB}"
    done
    echo OK ;;
esac
exit 0'

export PATH="${BIN}:${PATH}"

# ── fixtures ────────────────────────────────────────────────────────────────

# pulzr-modbus's addon, control and keep.d as they are (Modbus, on the shared
# pulzr-edge runtime, which is not needed for what this tests), and pulzr-meter,
# an add-on of no capability the deny names that depends on it.
FEED="${T}/feed"
mkdir -p "${FEED}/pulzr-modbus/files/lib/upgrade/keep.d" "${FEED}/pulzr-meter"
cp "${ROOT_DIR}"/feed/pulzr-modbus/{addon,control} "${FEED}/pulzr-modbus/"
cp "${ROOT_DIR}"/feed/pulzr-modbus/files/lib/upgrade/keep.d/* "${FEED}/pulzr-modbus/files/lib/upgrade/keep.d/"
printf 'ADDON_TITLE="Meter"\nADDON_CAPS="meter"\nADDON_FEATURE=""\nADDON_BOARDS="*"\n' > "${FEED}/pulzr-meter/addon"

# A package's payload, packed as the stand-in apk unpacks it. The init script
# and uci-defaults only say they ran; the health script is pulzr-modbus's own.
payload() {
  local name="$1" dir="${T}/payload-$1"
  rm -rf "${dir}"; mkdir -p "${dir}/etc/init.d" "${dir}/usr/libexec/pulzr/addon-health" "${dir}/etc/uci-defaults"
  printf '#!/bin/sh\necho "%s $1" >> "${T}/services.log"\n' "${name}" > "${dir}/etc/init.d/${name}"
  printf '#!/bin/sh\ntouch "${T}/uci-defaults-%s"\n' "${name}" > "${dir}/etc/uci-defaults/90-${name}"
  if [ "${name}" = pulzr-modbus ]; then
    cp "${ROOT_DIR}/feed/pulzr-modbus/files/usr/libexec/pulzr/addon-health/pulzr-modbus" "${dir}/usr/libexec/pulzr/addon-health/"
    mkdir -p "${dir}/lib/upgrade/keep.d" "${dir}/usr/sbin"
    cp "${ROOT_DIR}/feed/pulzr-modbus/files/lib/upgrade/keep.d/pulzr-modbus" "${dir}/lib/upgrade/keep.d/"
    head -c 40000 /dev/urandom > "${dir}/usr/sbin/pulzr-modbus"
  else
    printf '#!/bin/sh\nexit 0\n' > "${dir}/usr/libexec/pulzr/addon-health/${name}"
  fi
  chmod +x "${dir}"/etc/init.d/* "${dir}"/usr/libexec/pulzr/addon-health/*
  ( cd "${dir}" && tar -cf "$2" . )
}

sha() { if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

# The CDN for ${VERSION}: catalog, index and packages, as build-addons.sh lays
# them out.
serve() {
  local repo="${SERVE}/v${VERSION}/${ARCH}"
  rm -rf "${SERVE}"; mkdir -p "${repo}"
  payload pulzr-modbus "${repo}/pulzr-modbus-${PKGVER}.apk"
  payload pulzr-meter "${repo}/pulzr-meter-${PKGVER}.apk"
  { echo "pulzr-modbus ${PKGVER} pulzr-base=${PKGVER}"
    echo "pulzr-meter ${PKGVER} pulzr-modbus pulzr-base=${PKGVER}"; } > "${repo}/packages.adb"
  local entries=()
  for n in pulzr-modbus pulzr-meter; do
    local f="${repo}/${n}-${PKGVER}.apk"
    entries+=("$(jq -nc --arg n "${n}" --arg a "${ARCH}" --arg file "${n}-${PKGVER}.apk" \
                  --arg sha "$(sha "${f}")" --argjson bytes "$(wc -c < "${f}")" \
                  '{name:$n, arches:{($a):{file:$file, bytes:$bytes, installedBytes:$bytes, sha256:$sha}}}')")
  done
  printf '%s\n' "${entries[@]}" | jq -sc --arg tag "v${VERSION}" '{tag:$tag, addons:.}' > "${SERVE}/v${VERSION}/addons.json"
}

reset() {
  rm -rf "${R}" "${T}/apk" "${T}"/*.log "${T}"/uci-defaults-* "${T}/cut"
  mkdir -p "${R}/etc/pulzr" "${R}/etc/config" "${R}/overlay" "${T}/apk/files"
  : > "${T}/apk/installed"
  printf "BOARD_ID='rpi4'\nPULZR_VERSION='%s'\nPULZR_ADDONS_URL='%s'\nPULZR_ADDONS_BUILTIN='%s'\n" \
    "${VERSION}" "${BASE_URL}" "${1:-}" > "${R}/etc/pulzr/board.conf"
  "${ROOT_DIR}/scripts/addon-index.sh" "${FEED}" "${R}" || { echo "FAIL addon-index.sh"; exit 1; }
  echo '{"pulzr":{"storage":{".type":"storage","present":"0"}},"pulzr_addons":{"main":{".type":"addons",".name":"main"}}}' > "${UCI_JSON}"
  echo pass > "${T}/gate"
  echo good > "${T}/firmware"
  echo 500000 > "${T}/free_kb"
  echo "${PKGVER}" > "${T}/base_version"
  serve
}

# ── checks ──────────────────────────────────────────────────────────────────

fail=0
check() {
  local what="$1" expected="$2" actual="$3"
  if [ "${actual}" = "${expected}" ]; then
    echo "ok   ${what}"
  else
    echo "FAIL ${what}"
    echo "     expected: ${expected}"
    echo "     actual:   ${actual}"
    fail=1
  fi
}

addon() { pulzr-addon "$@" >/dev/null 2>"${T}/stderr"; }
item() { pulzr-addon status --brief | jq -r ".items[\"$1\"]${2:+.$2} // \"none\""; }
wanted() { pulzr-addon status --brief | jq -c .wanted; }
err() { tr -d '\n' < "${T}/stderr"; }
real_adds() { grep '^apk add' "${T}/apk.log" 2>/dev/null | grep -vc -- --simulate; }
STAGE="${R}/tmp/pulzr-addons/v${VERSION}/${ARCH}"

# ── install ─────────────────────────────────────────────────────────────────

reset
addon start install pulzr-modbus 'alice@example.com'; rc=$?
check "install: start accepted" 0 "${rc}"
check "install: installed" installed "$(item pulzr-modbus state)"
check "install: wanted" '["pulzr-modbus"]' "$(wanted)"
check "install: version from apk" "${PKGVER}" "$(item pulzr-modbus version)"
EDGE_VERSION="$(sed -n 's/^PKG_VERSION:=//p' "${ROOT_DIR}/sdk/packages/pulzr-edge/Makefile")"
check "install: upstream from addons.caps" "${EDGE_VERSION}" "$(item pulzr-modbus upstream)"
# No buses: idle, and an idle add-on is not removed.
check "install: idle without buses, and kept" idle "$(item pulzr-modbus health)"
check "install: service enabled and started" "pulzr-modbus enable pulzr-modbus start" "$(tr '\n' ' ' < "${T}/services.log" | sed 's/ $//')"
check "install: its uci-defaults ran" yes "$([ -f "${T}/uci-defaults-pulzr-modbus" ] && echo yes)"
check "install: and were deleted" no "$([ -f "${R}/etc/uci-defaults/90-pulzr-modbus" ] && echo yes || echo no)"
check "install: journal names who asked" 'installed alice@example.com' \
  "$(tail -n1 "${R}/etc/pulzr/addons/journal" | jq -r '"\(.result) \(.by)"')"
check "install: lock released" no "$([ -e "${R}/var/run/pulzr/addon.lock" ] && echo yes || echo no)"
check "install: reported" yes "$(grep -q report "${T}/claim.log" && echo yes)"
check "install: brief has only wanted, deny, items and free" '["deny","free","items","wanted"]' \
  "$(pulzr-addon status --brief | jq -c 'keys')"
check "install: brief item shape" '["builtIn","error","health","since","state","upstream","version"]' \
  "$(pulzr-addon status --brief | jq -c '.items["pulzr-modbus"] | keys')"
check "install: full status lists what the release offers" 'pulzr-meter Meter,pulzr-modbus Modbus' \
  "$(pulzr-addon status | jq -r '[.available[] | "\(.name) \(.title)"] | join(",")')"
addon start install pulzr-modbus alice; rc=$?
check "install: twice is refused" "3 Modbus is already installed." "${rc} $(err)"

# ── a download cut off half way ─────────────────────────────────────────────

reset
echo "pulzr-modbus-${PKGVER}.apk" > "${T}/cut"
addon install pulzr-modbus alice; rc=$?
check "resume: the cut-off attempt fails, to be retried" 75 "${rc}"
check "resume: and says so" failed "$(item pulzr-modbus state)"
half="$(wc -c < "${STAGE}/pulzr-modbus-${PKGVER}.apk.part" | tr -d ' ')"
check "resume: half the package is kept" yes "$([ "${half}" -gt 0 ] && echo yes)"
addon install pulzr-modbus alice; rc=$?
check "resume: the second attempt installs" "0 installed" "${rc} $(item pulzr-modbus state)"
check "resume: it resumed at the cut, not from zero" "resume=1 offset=${half}" \
  "$(grep "pulzr-modbus-${PKGVER}.apk" "${T}/curl.log" | tail -n1 | cut -d' ' -f2-)"
check "resume: the package is whole" "$(sha "${SERVE}/v${VERSION}/${ARCH}/pulzr-modbus-${PKGVER}.apk")" \
  "$(sha "${STAGE}/pulzr-modbus-${PKGVER}.apk")"

# ── refusals ────────────────────────────────────────────────────────────────

reset
printf 'x' >> "${SERVE}/v${VERSION}/${ARCH}/pulzr-modbus-${PKGVER}.apk"
addon install pulzr-modbus alice
check "sha: a package that does not match the catalog is refused" "failed pulzr-modbus-${PKGVER}.apk did not match its checksum." \
  "$(item pulzr-modbus state) $(item pulzr-modbus error)"
check "sha: and thrown away" no "$([ -e "${STAGE}/pulzr-modbus-${PKGVER}.apk.part" ] && echo yes || echo no)"
check "sha: apk never installed anything" 0 "$(real_adds)"

reset
echo 100 > "${T}/free_kb"
addon install pulzr-modbus alice; rc=$?
check "space: refused" "1 failed" "${rc} $(item pulzr-modbus state)"
check "space: says how much" yes "$(item pulzr-modbus error | grep -q 'KB free' && echo yes)"
check "space: before any package download" 0 "$(grep -c "\.apk" "${T}/curl.log")"

reset pulzr-modbus
echo "pulzr-modbus ${PKGVER}" > "${T}/apk/installed"
addon start install pulzr-modbus alice; rc=$?
check "built in: install refused" "3 Modbus is built into this gateway's firmware." "${rc} $(err)"
addon start remove pulzr-modbus alice; rc=$?
check "built in: remove refused" 3 "${rc}"
check "built in: reported as built in" "installed true" "$(item pulzr-modbus state) $(item pulzr-modbus builtIn)"

reset
echo pending > "${T}/firmware"
addon start install pulzr-modbus alice; rc=$?
check "pending firmware: refused" "3 A firmware upgrade is still being judged." "${rc} $(err)"
check "pending firmware: nothing downloaded" no "$([ -f "${T}/curl.log" ] && echo yes || echo no)"

reset
mkdir -p "${R}/var/run/pulzr/addon.lock"
printf '{"pid":%d,"action":"install","name":"pulzr-meter","at":0}' "$$" > "${R}/var/run/pulzr/addon.lock/job"
addon start install pulzr-modbus alice; rc=$?
check "busy: a second job is refused" "3 Another add-on job is running." "${rc} $(err)"
printf '{"pid":999999,"action":"install","name":"pulzr-meter","at":0}' > "${R}/var/run/pulzr/addon.lock/job"
addon start install pulzr-modbus alice; rc=$?
check "busy: a lock whose job is gone is taken over" "0 installed" "${rc} $(item pulzr-modbus state)"

reset
echo 0.5.0-r2 > "${T}/base_version"
addon install pulzr-modbus alice
check "pin: an add-on for another build of the release is refused" \
  "failed Modbus was not built for the firmware this gateway runs." "$(item pulzr-modbus state) $(item pulzr-modbus error)"

reset
jq -c '.addons |= map(if .name == "pulzr-modbus" then .arches = {} else . end)' \
  "${SERVE}/v${VERSION}/addons.json" > "${T}/c.json" && mv "${T}/c.json" "${SERVE}/v${VERSION}/addons.json"
addon install pulzr-modbus alice
check "arch: a release that does not build it here" unavailable "$(item pulzr-modbus state)"

# ── a production gateway: deny=modbus ──────────────────────────────────────────────

reset
addon deny 'staff@pulzr.net' 'this gateway never gets Modbus' modbus >/dev/null
check "deny: recorded" '["modbus"]' "$(pulzr-addon status --brief | jq -c .deny)"
addon start install pulzr-modbus alice; rc=$?
check "deny: pulzr-modbus refused by name" "3 Modbus is locked off on this gateway." "${rc} $(err)"
addon start install pulzr-meter alice
check "deny: refused through a dependency" "failed Modbus is locked off on this gateway." \
  "$(item pulzr-meter state) $(item pulzr-meter error)"
check "deny: nothing installed" "0 none" "$(real_adds) $(item pulzr-modbus state)"
# Somebody edits wanted by hand; restore must not bring Modbus back.
jq -c '.pulzr_addons.main.wanted = ["pulzr-modbus"]' "${UCI_JSON}" > "${T}/u.json" && mv "${T}/u.json" "${UCI_JSON}"
: > "${T}/apk.log"
addon restore; rc=$?
check "deny: restore of a hand-edited wanted refuses" "0 failed Modbus is locked off on this gateway." \
  "${rc} $(item pulzr-modbus state) $(item pulzr-modbus error)"
check "deny: restore never asked apk to add it" 0 "$(grep -c '^apk add' "${T}/apk.log")"
addon deny 'staff@pulzr.net' 'again' meter >/dev/null
check "deny: only ever adds" '["modbus","meter"]' "$(pulzr-addon status --brief | jq -c .deny)"
addon undeny modbus meter >/dev/null
addon restore
check "undeny: from a shell, and restore then installs" installed "$(item pulzr-modbus state)"

# ── the gate ────────────────────────────────────────────────────────────────

reset
printf 'pass\nfail\n' > "${T}/gate"
addon install pulzr-modbus alice; rc=$?
check "gate: a gateway that stops reaching Pulzar Cloud undoes the add-on" \
  "1 reverted After the install the gateway could not reach Pulzar Cloud." \
  "${rc} $(item pulzr-modbus state) $(item pulzr-modbus error)"
check "gate: removed" "" "$(cat "${T}/apk/installed")"
check "gate: not wanted" '[]' "$(wanted)"
check "gate: services stopped and disabled" "pulzr-modbus enable pulzr-modbus start pulzr-modbus stop pulzr-modbus disable" \
  "$(tr '\n' ' ' < "${T}/services.log" | sed 's/ $//')"

reset
echo fail > "${T}/gate"
addon install pulzr-modbus alice; rc=$?
check "gate: no install when the gateway is already unhealthy" "75 0" "${rc} $(real_adds)"

# ── remove ──────────────────────────────────────────────────────────────────

reset
addon install pulzr-modbus alice
mkdir -p "${R}/etc/pulzr-edge/radios"; echo '[[bus]]' > "${R}/etc/pulzr-edge/buses.toml"
echo '{"protocol":"zigbee"}' > "${R}/etc/pulzr-edge/radios/usb-1.json"
addon start remove pulzr-modbus bob; rc=$?
check "remove: removed" "0 none" "${rc} $(item pulzr-modbus state)"
check "remove: not wanted" '[]' "$(wanted)"
check "remove: the buses are kept" '[[bus]]' "$(cat "${R}/etc/pulzr-edge/buses.toml" 2>/dev/null)"
check "remove: its files are gone" no "$([ -e "${R}/etc/init.d/pulzr-modbus" ] && echo yes || echo no)"
addon install pulzr-modbus alice
addon remove pulzr-modbus bob --purge
check "remove --purge: the buses go too" no "$([ -e "${R}/etc/pulzr-edge/buses.toml" ] && echo yes || echo no)"
check "remove --purge: a Zigbee network's keys beside them stay" yes "$([ -e "${R}/etc/pulzr-edge/radios/usb-1.json" ] && echo yes || echo no)"

# ── restore after an upgrade ────────────────────────────────────────────────

reset
# What sysupgrade leaves: UCI says it was installed, the overlay has no package.
jq -c '.pulzr_addons.main.wanted = ["pulzr-modbus"]
       | .pulzr_addons.pulzr_edge = {".type":"addon",".name":"pulzr_edge","name":"pulzr-modbus","state":"installed","since":"2026-11-20T10:02:11Z"}' \
  "${UCI_JSON}" > "${T}/u.json" && mv "${T}/u.json" "${UCI_JSON}"
check "restore: an upgraded gateway reads pending-restore" pending-restore "$(item pulzr-modbus state)"
addon restore; rc=$?
check "restore: installs what is wanted" "0 installed" "${rc} $(item pulzr-modbus state)"
check "restore: and nothing else" "pulzr-modbus" "$(cut -d' ' -f1 "${T}/apk/installed" | tr '\n' ' ' | sed 's/ $//')"
: > "${T}/curl.log"
addon restore
check "restore: a second run has nothing to do" "" "$(cat "${T}/curl.log")"

reset
jq -c '.pulzr_addons.main.wanted = ["pulzr-gone"]' "${UCI_JSON}" > "${T}/u.json" && mv "${T}/u.json" "${UCI_JSON}"
addon restore; rc=$?
check "restore: an add-on this release dropped is unavailable" "0 unavailable" "${rc} $(item pulzr-gone state)"
check "restore: and stays wanted" '["pulzr-gone"]' "$(wanted)"
: > "${T}/claim.log"
addon restore
check "restore: what cannot be restored is journaled once, not at every boot" "1 0" \
  "$(grep -c pulzr-gone "${R}/etc/pulzr/addons/journal") $(wc -l < "${T}/claim.log" | tr -d ' ')"

reset
jq -c '.pulzr_addons.main.wanted = ["pulzr-modbus"]' "${UCI_JSON}" > "${T}/u.json" && mv "${T}/u.json" "${UCI_JSON}"
rm -rf "${SERVE}"
addon restore; rc=$?
check "restore: an unreachable repository is tried again later" "75 failed" "${rc} $(item pulzr-modbus state)"
check "restore: still wanted" '["pulzr-modbus"]' "$(wanted)"

[ "${fail}" = 0 ] && echo "pulzr-addon ok"
exit "${fail}"
