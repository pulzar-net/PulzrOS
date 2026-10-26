#!/usr/bin/env bash
#
# Stage feed/<name>/ directories as package payloads, ready for build.sh to
# pack into .apk files with the ImageBuilder's own apk.
#
#   build-feed.sh <feed-dir> <stage-dir> <version> <build>
#
# Each package becomes <stage-dir>/<name>_<arch>.tar: its rootfs under ./data,
# and ./info, its apk metadata as the KEY:VALUE lines `apk mkpkg --info` takes.
#
# Staged here rather than packed here because an .apk is apk's own binary
# format, and the one apk that writes it for this release is the x86_64 Linux
# binary inside the ImageBuilder. This half runs on a Mac as often as in CI and
# needs nothing but tar; the packing happens beside `make image`, where that
# binary is (pack_feed in build.sh). A tar rather than a directory because a
# CI artifact keeps neither file modes nor owners, and the tar keeps both.
#
# We do not use the OpenWrt SDK. Every package here is interpreted code, static
# files, or upstream binaries fetched by checksum, with no compile step, and
# the SDK is a multi-gigabyte download whose only contribution would be to run
# `tar` for us. If a package ever gains a C source file, it moves to the SDK
# and this script stops being the right tool for it.
#
# A package with an `arches` file is built once per line of it, for binaries:
# its control file says `Architecture: @ARCH@`, the second column becomes its
# Depends, and its executable `fetch <arch> <root> <cache>` adds the payload.

set -euo pipefail

FEED_DIR="${1:?feed dir}"
STAGE_DIR="${2:?stage dir}"
VERSION="${3:?version}"
BUILD="${4:?build}"

# apk refuses a version it cannot order, and "0.3.4-dev-202610261200" is one:
# a release is <digits>[.<digits>...] and the only thing after a hyphen is
# -r<digits>. So the package version is the release number with the build
# stamp as its revision. A bench build's -dev stays in board.conf and on every
# screen, which is where anybody reads it; nothing reads a package's version.
PKG_VERSION="${VERSION%%-*}-r${BUILD}"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# ── portability ─────────────────────────────────────────────────────────────
#
# The reproducibility flags (--mtime, --sort, --owner) are GNU tar's. macOS
# ships bsdtar, which rejects --mtime outright rather than ignoring it. Use GNU
# tar when it is available and bsdtar's own spelling of root ownership when it
# is not: the payload is still correct, it just is not byte-reproducible,
# which matters for diffing a rebuilt image against a shipped one and does not
# matter for getting a build out. Ownership is not optional either way: pack_feed
# packs under fakeroot, which turns the real user into root, but a uid stored
# in the tar would come back out as that uid.
if command -v gtar >/dev/null 2>&1; then TAR=gtar; else TAR=tar; fi
if "${TAR}" --version 2>/dev/null | grep -qi 'gnu tar'; then
  tar_create() {
    "${TAR}" --numeric-owner --owner=0 --group=0 --mtime="@0" --sort=name -cf "$1" .
  }
else
  echo "note: GNU tar not found, so the staged packages will not be byte-reproducible."
  echo "      brew install gnu-tar   (for reproducible builds on macOS)"
  # --no-mac-metadata, or every file with an extended attribute (which cp -a
  # gives most of them on a Mac) brings a ._<name> AppleDouble file with it,
  # and that lands in the image beside the real one. --no-xattrs, or the same
  # attributes ride along as pax headers that GNU tar warns about per file.
  tar_create() { "${TAR}" --uid 0 --gid 0 --no-mac-metadata --no-xattrs -cf "$1" .; }
fi

mkdir -p "${STAGE_DIR}"

CACHE_DIR="${STAGE_DIR}/../downloads"

package_one() {
  local pkgdir="$1" name="$2" want_arch="$3" depends="$4"
  local stage="${WORK}/${name}-${want_arch}"
  rm -rf "${stage}"; mkdir -p "${stage}/data"

  # The package's rootfs is everything under files/.
  [ -d "${pkgdir}/files" ] && cp -a "${pkgdir}/files/." "${stage}/data/"

  # A release ships our code without its source commentary: ucode compiled,
  # shell comments dropped. Before fetch, so upstream binaries are left alone.
  # build.sh sets UCODE for every build that is not a bench build.
  if [ -n "${UCODE:-}" ]; then
    "$(dirname "$0")/harden-payload.sh" "${stage}/data"
  fi

  if [ -x "${pkgdir}/fetch" ]; then
    "${pkgdir}/fetch" "${want_arch}" "${stage}/data" "${CACHE_DIR}"
  fi

  # Anything executable in the payload must stay executable through the tar.
  #
  # A safety net rather than the only mechanism — the source files carry their
  # own modes — but a new script added without `chmod +x` would otherwise ship
  # non-executable and fail silently at the one moment it is needed.
  #
  # /etc/profile.d is deliberately absent: those are sourced, not executed, and
  # marking them executable would be misleading about how they run.
  find "${stage}/data" -type f \
    \( -path '*/etc/init.d/*' -o -path '*/usr/bin/*' -o -path '*/usr/sbin/*' \
       -o -path '*/etc/uci-defaults/*' -o -path '*/usr/libexec/*' \
       -o -path '*/etc/hotplug.d/*' -o -path '*/etc/rc.button/*' \
       -o -path '*/etc/rc.local' \) \
    -exec chmod 0755 {} +

  # An empty payload installs nothing and says nothing about it, which is how
  # an image once booted with none of ParkezeOS in it. Refused here.
  [ -n "$(find "${stage}/data" -type f -print -quit)" ] \
    || { echo "error: ${name} (${want_arch:-all}) has no files to ship" >&2; exit 1; }

  # The control file is the Debian-style source of truth for a package's
  # metadata; apk wants it as KEY:VALUE pairs. The Description's continuation
  # lines fold into one, and Depends loses its commas, which is apk's spelling.
  local control="${WORK}/${name}-${want_arch}.control"
  sed -e "s/@ARCH@/${want_arch}/g" "${pkgdir}/control" > "${control}"
  if [ -n "${depends}" ] && [ "${depends}" != "-" ]; then
    echo "Depends: ${depends}" >> "${control}"
  fi
  local arch
  arch="$(awk -F': *' '/^Architecture:/ { print $2 }' "${control}")"
  [ "${arch}" = all ] && arch=noarch
  {
    echo "name:${name}"
    echo "version:${PKG_VERSION}"
    echo "arch:${arch}"
    echo "origin:parkeze"
    awk '/^Maintainer:/ { sub(/^Maintainer: */, ""); print "maintainer:" $0 }' "${control}"
    awk '/^Depends:/ { sub(/^Depends: */, ""); gsub(/, */, " "); d = d (d ? " " : "") $0 }
         END { if (d) print "depends:" d }' "${control}"
    awk '/^Description:/ { sub(/^Description: */, ""); d = $0; on = 1; next }
         on && /^ / { sub(/^ +/, ""); d = d " " $0; next }
         { on = 0 }
         END { print "description:" d }' "${control}"
  } > "${stage}/info"

  local out="${STAGE_DIR}/${name}_${arch}.tar"
  ( cd "${stage}" && tar_create "${out}.partial" ) && mv "${out}.partial" "${out}"
  echo "  staged ${name} ${PKG_VERSION} (${arch})"
}

# Every package is restaged on every run, so nothing a feed/ directory no
# longer has can linger here and be packed into an image.
rm -f "${STAGE_DIR}"/*.tar

for pkgdir in "${FEED_DIR}"/*/; do
  name="$(basename "${pkgdir}")"
  [ -f "${pkgdir}/control" ] || { echo "skip ${name}: no control file"; continue; }

  if [ -f "${pkgdir}/arches" ]; then
    while read -r arch depends; do
      case "${arch}" in ''|'#'*) continue ;; esac
      package_one "${pkgdir}" "${name}" "${arch}" "${depends//,/ }"
    done < "${pkgdir}/arches"
  else
    package_one "${pkgdir}" "${name}" "" ""
  fi
done

echo "Feed staged at ${STAGE_DIR}"
