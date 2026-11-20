#!/usr/bin/env bash
#
# Build the signed add-on repository for one release: an apk repository per
# architecture, and the catalog that lists them.
#
#   build-addons.sh <imagebuilder-dir> <stage-dir> <out-dir> <tag>
#
#   <out-dir>/<arch>/<name>-<version>.apk
#   <out-dir>/<arch>/packages.adb          the index, signed
#   <out-dir>/addons.json                  the catalog
#   <out-dir>/PUBLISHABLE                  only if signed with the real key
#
# <stage-dir> is what build-feed.sh staged: the add-ons are packed from the
# same tars as the packages in the images, so an add-on's pulzr-base pin names
# the pulzr-base those images carry. Packing and indexing use the
# ImageBuilder's own apk, the one apk that writes this release's format, so
# nothing here needs apk on the host.
#
# The signing key is PULZR_ADDONS_APK_KEY_FILE, an ECDSA P-256 PEM. Without it
# the whole build still runs, against a throwaway key, so a broken add-on fails
# on every push; but nothing signed with a throwaway key is publishable, and
# PUBLISHABLE is how the workflow knows. The real key must be the private half
# of the committed feed/pulzr-base/files/etc/apk/keys/pulzr-addons.pem: that
# file is what gateways trust, and an index signed by any other key is one
# they would refuse, so it is refused here, before upload.
#
# Everything is checked where it was made: the index is read back with
# signature checking on, against the committed public key, and must also be
# REFUSED when no key is trusted. A check that cannot fail proves nothing.

set -euo pipefail

IB="${1:?imagebuilder dir}"
STAGE="${2:?stage dir}"
OUT="${3:?out dir}"
TAG="${4:?tag}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FEED_DIR="${ROOT_DIR}/feed"
BOARDS_DIR="${ROOT_DIR}/boards"
PUBKEY="${FEED_DIR}/pulzr-base/files/etc/apk/keys/pulzr-addons.pem"

die() { echo "error: $*" >&2; exit 1; }

HOST="${IB}/staging_dir/host"
APK="${HOST}/bin/apk"
[ -x "${APK}" ] || die "this ImageBuilder has no apk: ${APK}"
for tool in jq openssl; do command -v "${tool}" >/dev/null || die "${tool} is required"; done
[ -f "${PUBKEY}" ] || die "the committed add-ons public key is missing: ${PUBKEY}"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
rm -rf "${OUT}"; mkdir -p "${OUT}"

# PEM body only: the files carry an `untrusted comment:` line first, which is
# apk's and OpenWrt's habit, and openssl is not asked to read it.
pem_body() { sed -n '/-----BEGIN/,/-----END/p' "$1"; }

# ── the key ────────────────────────────────────────────────────────────────

KEYS="${WORK}/keys"; mkdir -p "${KEYS}"
SIGN_KEY="${WORK}/sign.pem"
publishable=0
if [ -n "${PULZR_ADDONS_APK_KEY_FILE:-}" ]; then
  [ -s "${PULZR_ADDONS_APK_KEY_FILE}" ] || die "PULZR_ADDONS_APK_KEY_FILE is empty or missing"
  cp "${PULZR_ADDONS_APK_KEY_FILE}" "${SIGN_KEY}"
  derived="$(pem_body "${SIGN_KEY}" | openssl ec -pubout 2>/dev/null)" \
    || die "PULZR_ADDONS_APK_KEY_FILE is not an EC private key"
  [ "${derived}" = "$(pem_body "${PUBKEY}")" ] \
    || die "the signing key is not the private half of ${PUBKEY}"
  cp "${PUBKEY}" "${KEYS}/pulzr-addons.pem"
  publishable=1
else
  echo "note: no PULZR_ADDONS_APK_KEY_FILE; signing with a throwaway key. Not publishable."
  openssl ecparam -name prime256v1 -genkey -noout -out "${SIGN_KEY}"
  pem_body "${SIGN_KEY}" | openssl ec -pubout > "${KEYS}/throwaway.pem" 2>/dev/null
fi
chmod 0600 "${SIGN_KEY}"
mkdir -p "${WORK}/nokeys"

# ── pack ───────────────────────────────────────────────────────────────────

sha256() { sha256sum "$1" | cut -d' ' -f1; }

# One JSON object per (add-on, architecture), joined into the catalog below.
ENTRIES="${WORK}/entries.jsonl"; : > "${ENTRIES}"
# One per (upstream package, architecture, add-on that brings it).
UPSTREAM="${WORK}/upstream.jsonl"; : > "${UPSTREAM}"

# OpenWrt's own package keys, which the ImageBuilder trusts for its feeds:
# what addon-upstream.sh checks each upstream package against.
OPENWRT_KEYS="$(find "${IB}" -maxdepth 3 -type d -name keys -exec sh -c 'ls "$1"/*.pem >/dev/null 2>&1' _ {} \; -print | head -n1)"
[ -n "${OPENWRT_KEYS}" ] || die "this ImageBuilder has no keys directory with OpenWrt's public keys"

# The OpenWrt target a package architecture is built on, from the boards.
target_of() {
  local conf
  for conf in "${BOARDS_DIR}"/*/board.conf; do
    [ "${conf}" = "${BOARDS_DIR}/common/board.conf" ] && continue
    ( BOARDS_DIR="${BOARDS_DIR}"; . "${conf}"
      [ "${OPENWRT_ARCH:-}" = "$1" ] && echo "${OPENWRT_TARGET}/${OPENWRT_SUBTARGET}" ) && return 0
  done
  return 1
}

common_package() {
  ( . "${BOARDS_DIR}/common/board.conf"
    printf '%s\n' "${PACKAGES_COMMON}" | sed 's/#.*//' | tr -s '[:space:]' '\n' | grep -qxF "$1" )
}

ARCHES_SEEN="${WORK}/arches.txt"; : > "${ARCHES_SEEN}"
found=0

for pkgdir in "${FEED_DIR}"/*/; do
  [ -f "${pkgdir}/addon" ] || continue
  name="$(basename "${pkgdir}")"
  [ -f "${pkgdir}/arches" ] || die "${name} is an add-on with no arches file"
  found=$((found + 1))

  # shellcheck disable=SC1091
  ( . "${pkgdir}/addon"
    : "${ADDON_TITLE:?${name}/addon needs ADDON_TITLE}" "${ADDON_CAPS:?${name}/addon needs ADDON_CAPS}" ) \
    || exit 1
  title="$(. "${pkgdir}/addon"; echo "${ADDON_TITLE}")"
  caps="$(. "${pkgdir}/addon"; echo "${ADDON_CAPS}")"
  # The upstream release the binary comes from, from the one place it is pinned.
  # Its upstream version: an SDK recipe's PKG_VERSION, else a fetch's VERSION=.
  upstream="$(sed -n 's/^PKG_VERSION:=//p' "${ROOT_DIR}/sdk/packages/$(basename "${pkgdir}")/Makefile" 2>/dev/null | head -n1 || true)"
  [ -n "${upstream}" ] || upstream="$(sed -n 's/^VERSION=//p' "${pkgdir}/fetch" 2>/dev/null | head -n1 | tr -d '"' || true)"
  keep="$(cat "${pkgdir}"/files/lib/upgrade/keep.d/* 2>/dev/null | grep -v '^[[:space:]]*\(#\|$\)' || true)"

  # Boards that carry it in the image, from their own config.
  builtin="[]"
  for conf in "${BOARDS_DIR}"/*/board.conf; do
    id="$(basename "$(dirname "${conf}")")"; [ "${id}" = common ] && continue
    if ( BOARDS_DIR="${BOARDS_DIR}"; . "${conf}"
         case " ${PULZR_ADDONS_BUILTIN:-} " in *" ${name} "*) exit 0 ;; esac; exit 1 ); then
      builtin="$(jq -c --arg b "${id}" '. + [$b]' <<<"${builtin}")"
    fi
  done

  # On fd 3: apk and tar below read stdin, and would eat the rest of the list.
  while read -r arch _ <&3; do
    case "${arch}" in ''|'#'*) continue ;; esac
    tar="${STAGE}/${name}_${arch}.tar"
    [ -f "${tar}" ] || die "no staged ${name} for ${arch} in ${STAGE}; run ./build.sh --stage feed"

    tmp="${WORK}/pack-${name}-${arch}"; rm -rf "${tmp}"; mkdir -p "${tmp}"
    tar -xf "${tar}" -C "${tmp}"
    info=()
    while IFS= read -r line; do info+=(--info "${line}"); done < "${tmp}/info"
    version="$(sed -n 's/^version://p' "${tmp}/info")"
    mkdir -p "${OUT}/${arch}"
    file="${name}-${version}.apk"

    # Under fakeroot for the same reason pack_feed is: apk records each file's
    # owner, and outside it every file would belong to whoever ran this.
    PATH="${HOST}/bin:${PATH}" "${HOST}/bin/fakeroot" \
      -l "${HOST}/lib/libfakeroot.so" -f "${HOST}/bin/faked" -- \
      "${APK}" mkpkg "${info[@]}" --files "${tmp}/data" --output "${OUT}/${arch}/${file}" \
      || die "apk could not pack ${name} for ${arch}"

    jq -nc --arg name "${name}" --arg title "${title}" --arg caps "${caps}" \
          --arg upstream "${upstream}" --argjson builtin "${builtin}" --arg keep "${keep}" \
          --arg arch "${arch}" --arg file "${file}" \
          --argjson bytes "$(stat -c %s "${OUT}/${arch}/${file}")" \
          --argjson installed "$(du -sb "${tmp}/data" | cut -f1)" \
          --arg sha "$(sha256 "${OUT}/${arch}/${file}")" \
      '{name:$name, title:$title, caps:($caps|split(" ")|map(select(length>0))), upstream:$upstream,
        builtIn:$builtin, keep:($keep|split("\n")|map(select(length>0))),
        arch:$arch, file:$file, bytes:$bytes, installedBytes:$installed, sha256:$sha}' \
      >> "${ENTRIES}"
    echo "${arch}" >> "${ARCHES_SEEN}"
    rm -rf "${tmp}"
    echo "  packed ${file} (${arch})"

    # The OpenWrt packages it brings, from the release's feeds as they are
    # (scripts/addon-upstream.sh). Several add-ons may bring the same one, and
    # each arch's repository holds it once.
    if [ -f "${pkgdir}/upstream" ]; then
      target="$(target_of "${arch}")" || die "no board runs ${arch}, so ${name}'s upstream packages have no target"
      kmods="${WORK}/kmods-${name}-${arch}"
      upstream_names="$("${ROOT_DIR}/scripts/addon-upstream.sh" "${APK}" "${OPENWRT_KEYS}" "${arch}" "${target}" \
          "${OUT}/${arch}" $(grep -v '^[[:space:]]*\(#\|$\)' "${pkgdir}/upstream") 2>"${kmods}")" \
        || { cat "${kmods}" >&2; die "could not fetch ${name}'s upstream packages for ${arch}"; }
      # A kernel module comes with the image, never with an add-on.
      for kmod in $(sed -n 's/^kmod //p' "${kmods}"); do
        common_package "${kmod}" || die "${name} needs ${kmod}, which is not in PACKAGES_COMMON"
      done
      for dep in ${upstream_names}; do
        f="$(cd "${OUT}/${arch}" && ls "${dep}"-[0-9]*.apk 2>/dev/null | head -n1)"
        [ -n "${f}" ] || die "addon-upstream.sh named ${dep} for ${arch} and wrote no file for it"
        jq -nc --arg name "${dep}" --arg by "${name}" --arg arch "${arch}" --arg file "${f}" \
              --argjson bytes "$(stat -c %s "${OUT}/${arch}/${f}")" \
              --argjson installed "$("${APK}" adbdump "${OUT}/${arch}/${f}" | sed -n 's/^  installed-size: //p' | head -n1)" \
              --arg sha "$(sha256 "${OUT}/${arch}/${f}")" \
          '{name:$name, by:$by, arch:$arch, file:$file, bytes:$bytes, installedBytes:$installed, sha256:$sha}' \
          >> "${UPSTREAM}"
        echo "  fetched ${f} (${arch}, for ${name})"
      done
    fi
  done 3< "${pkgdir}/arches"
done

[ "${found}" -gt 0 ] || die "no add-ons in ${FEED_DIR} (no feed/*/addon file)"

# ── index, sign, verify ────────────────────────────────────────────────────

# Same flags as the ImageBuilder's own package_index target (its Makefile):
# --sign takes the private key. --allow-untrusted is about the INPUT packages,
# which are the unsigned ones packed above; the index is what gets signed, and
# it carries each package's hash.
for arch in $(sort -u "${ARCHES_SEEN}"); do
  ( cd "${OUT}/${arch}" && "${APK}" mkndx \
      --keys-dir "${KEYS}" --sign "${SIGN_KEY}" \
      --allow-untrusted --output packages.adb ./*.apk ) \
    || die "apk mkndx failed for ${arch}"
  [ -s "${OUT}/${arch}/packages.adb" ] || die "apk mkndx wrote no index for ${arch}"

  # Read the index back as a gateway does: a local packages.adb as the only
  # repository, signature checking on. apk is given an empty root of its own,
  # with the empty database an initialised root has: apk-tools 3 will not
  # open a root without one ("Unable to read database").
  readback() {
    local keys="$1" root; root="$(mktemp -d "${WORK}/root.XXXXXX")"
    mkdir -p "${root}/lib/apk/db" "${root}/etc/apk"
    : > "${root}/lib/apk/db/installed"
    : > "${root}/etc/apk/world"
    "${APK}" --root "${root}" --keys-dir "${keys}" --no-cache --no-interactive \
      --repositories-file /dev/null --repository "${OUT}/${arch}/packages.adb" \
      --arch "${arch}" list 2>&1
  }
  listing="$(readback "${KEYS}")" \
    || die "the signed index for ${arch} cannot be read with its own key:
${listing}"
  grep -q '^pulzr-' <<<"${listing}" \
    || die "the index for ${arch} lists no add-on:
${listing}"
  # Without the key apk-tools 3 does not fail: it skips the untrusted index
  # and lists nothing from it. So the proof is that no add-on is listed.
  if readback "${WORK}/nokeys" 2>/dev/null | grep -q '^pulzr-'; then
    die "apk read the index for ${arch} with no trusted key: the signature is not being checked"
  fi
  echo "  indexed and verified ${arch}"
done

# ── catalog ────────────────────────────────────────────────────────────────

jq -sc --arg tag "${TAG}" '
  { tag: $tag,
    addons: ( group_by(.name) | map(
      { name: .[0].name, title: .[0].title, caps: .[0].caps,
        upstream: .[0].upstream, builtIn: .[0].builtIn, keep: .[0].keep,
        arches: ( map({ key: .arch, value: {file, bytes, installedBytes, sha256} })
                  | from_entries ) } ) ),
    upstream: $up } ' \
  --argjson up "$(jq -sc 'group_by(.name) | map(
      { name: .[0].name, by: (map(.by) | unique),
        arches: ( group_by(.arch) | map({ key: .[0].arch, value: (.[0] | {file, bytes, installedBytes, sha256}) })
                  | from_entries ) })' "${UPSTREAM}")" \
  "${ENTRIES}" > "${OUT}/addons.json"

if [ "${publishable}" = 1 ]; then : > "${OUT}/PUBLISHABLE"; fi
echo "Add-ons for ${TAG} staged at ${OUT}"
