#!/usr/bin/env bash
#
# Package feed/<name>/ directories into .ipk files and index them into a local
# opkg repository the ImageBuilder can install from.
#
#   build-feed.sh <feed-dir> <repo-dir> <version> <build> <commit>
#
# We build the .ipk by hand rather than through the OpenWrt SDK. Every package
# here is interpreted code and static files with no compile step, and the SDK
# is a multi-gigabyte download whose only contribution would be to run `tar`
# for us. If a package ever gains a C source file, it moves to the SDK and this
# script stops being the right tool for it.

set -euo pipefail

FEED_DIR="${1:?feed dir}"
REPO_DIR="${2:?repo dir}"
VERSION="${3:?version}"
BUILD="${4:?build}"
COMMIT="${5:?commit}"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# ── portability ─────────────────────────────────────────────────────────────
#
# This runs on a developer's Mac as often as in CI, and the two disagree about
# both of the tools below.
#
# tar: the reproducibility flags (--mtime, --sort) are GNU extensions. macOS
# ships bsdtar, which rejects --mtime outright rather than ignoring it, so the
# packager died on the first package. Use GNU tar when it is available and fall
# back to a plain archive when it is not — the .ipk is still correct, it just
# is not byte-reproducible, which matters for diffing a rebuilt image against a
# shipped one and does not matter for getting a build out.
TAR=tar
REPRODUCIBLE=1
if command -v gtar >/dev/null 2>&1; then
  TAR=gtar
elif ! tar --version 2>/dev/null | grep -qi 'gnu tar'; then
  REPRODUCIBLE=0
  echo "note: GNU tar not found — packages will not be byte-reproducible."
  echo "      brew install gnu-tar   (for reproducible builds on macOS)"
fi

tar_create() {
  # tar_create <output.tar.gz> — archives the current directory.
  if [ "${REPRODUCIBLE}" = 1 ]; then
    "${TAR}" --numeric-owner --owner=0 --group=0 --mtime="@0" --sort=name \
        -czf "$1" .
  else
    "${TAR}" -czf "$1" .
  fi
}

# sha256: coreutils on Linux, shasum on macOS. Neither is present on both.
if command -v sha256sum >/dev/null 2>&1; then
  sha256() { sha256sum "$1" | cut -d' ' -f1; }
elif command -v shasum >/dev/null 2>&1; then
  sha256() { shasum -a 256 "$1" | cut -d' ' -f1; }
else
  echo "error: need sha256sum or shasum" >&2
  exit 1
fi

mkdir -p "${REPO_DIR}"

for pkgdir in "${FEED_DIR}"/*/; do
  name="$(basename "${pkgdir}")"
  [ -f "${pkgdir}/control" ] || { echo "skip ${name}: no control file"; continue; }

  stage="${WORK}/${name}"
  rm -rf "${stage}"; mkdir -p "${stage}/CONTROL"

  # The package's rootfs is everything under files/.
  if [ -d "${pkgdir}/files" ]; then
    mkdir -p "${stage}/data"
    cp -a "${pkgdir}/files/." "${stage}/data/"
  else
    mkdir -p "${stage}/data"
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

  # control, with the version stamped in at build time so the .ipk version and
  # the version the console reports cannot disagree.
  sed -e "s/@VERSION@/${VERSION}/g" \
      -e "s/@BUILD@/${BUILD}/g" \
      -e "s/@COMMIT@/${COMMIT}/g" \
      "${pkgdir}/control" > "${stage}/CONTROL/control"

  for script in preinst postinst prerm postrm conffiles; do
    [ -f "${pkgdir}/${script}" ] || continue
    cp "${pkgdir}/${script}" "${stage}/CONTROL/${script}"
    [ "${script}" = conffiles ] || chmod 0755 "${stage}/CONTROL/${script}"
  done

  # ipk layout: an ar archive of debian-binary, control.tar.gz, data.tar.gz.
  # --numeric-owner and a fixed mtime keep the output reproducible: two builds
  # of an unchanged tree should produce byte-identical packages, so that a
  # rebuilt image can be diffed against a shipped one meaningfully.
  ( cd "${stage}/data" && tar_create "${stage}/data.tar.gz" )
  ( cd "${stage}/CONTROL" && tar_create "${stage}/control.tar.gz" )
  echo "2.0" > "${stage}/debian-binary"

  arch="$(awk -F': *' '/^Architecture:/{print $2}' "${stage}/CONTROL/control")"
  out="${REPO_DIR}/${name}_${VERSION}-${BUILD}_${arch}.ipk"

  # Clear every other build of this package first. BUILD is a timestamp, so
  # without this the repo accumulates one .ipk per build forever, the Packages
  # index lists all of them, and a glob over the directory silently matches
  # several — which is how a stale control file gets read while debugging and
  # sends you looking for a bug that was fixed two builds ago.
  rm -f "${REPO_DIR}/${name}"_*.ipk
  ( cd "${stage}" && ar -rc "${out}" debian-binary control.tar.gz data.tar.gz )

  echo "  packaged ${name} ${VERSION}-${BUILD} (${arch})"
done

# Index. ImageBuilder reads Packages.gz out of a `src` line in repositories.conf;
# build.sh writes that line, this writes the file it points at.
(
  cd "${REPO_DIR}"
  : > Packages
  for ipk in *.ipk; do
    [ -e "${ipk}" ] || continue
    tmp="$(mktemp -d)"
    ar -p "${ipk}" control.tar.gz | tar -xzf - -C "${tmp}"
    cat "${tmp}/control" >> Packages
    printf 'Filename: %s\n' "${ipk}" >> Packages
    printf 'Size: %s\n' "$(wc -c < "${ipk}" | tr -d ' ')" >> Packages
    printf 'SHA256sum: %s\n\n' "$(sha256 "${ipk}")" >> Packages
    rm -rf "${tmp}"
  done
  gzip -9nkf Packages
)

echo "Feed indexed at ${REPO_DIR}"
