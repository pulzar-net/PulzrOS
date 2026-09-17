#!/usr/bin/env bash
#
# Package feed/<name>/ directories into .ipk files and index them into a local
# opkg repository the ImageBuilder can install from.
#
#   build-feed.sh <feed-dir> <repo-dir> <version> <build> <commit>
#
# We build the .ipk by hand rather than through the OpenWrt SDK. Every package
# here is interpreted code, static files, or upstream binaries fetched by
# checksum, with no compile step, and the SDK is a multi-gigabyte download whose
# only contribution would be to run `tar` for us. If a package ever gains a C
# source file, it moves to the SDK and this script stops being the right tool
# for it.
#
# A package with an `arches` file is built once per line of it, for binaries:
# its control file says `Architecture: @ARCH@`, the second column becomes its
# Depends, and its executable `fetch <arch> <root> <cache>` adds the payload.

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

tar_create_files() {
  # tar_create_files <output.tar.gz> <file>... — archives named files, in the
  # order given, each with a ./ prefix so the layout matches OpenWrt's own.
  local out="$1"; shift
  local paths=()
  local f
  for f in "$@"; do paths+=("./${f}"); done
  if [ "${REPRODUCIBLE}" = 1 ]; then
    "${TAR}" --numeric-owner --owner=0 --group=0 --mtime="@0" \
        -czf "${out}" "${paths[@]}"
  else
    "${TAR}" -czf "${out}" "${paths[@]}"
  fi
}

# An ipk opkg cannot read fails silently — it installs the metadata and no
# files — so the format is asserted at build time rather than discovered on a
# gateway. `file` is used deliberately: bsdtar reads ar archives too and would
# report success on the broken form.
check_ipk_format() {
  local ipk="$1" kind
  kind="$(file -b "${ipk}")"
  case "${kind}" in
    *gzip*) ;;
    *) echo "error: ${ipk} is '${kind}', not a gzipped tar." >&2
       echo "       OpenWrt's opkg only reads the tar.gz form; an ar archive" >&2
       echo "       installs zero files without reporting an error." >&2
       exit 1 ;;
  esac

  # And it must actually carry a payload.
  local entries
  entries="$(tar -xzOf "${ipk}" ./data.tar.gz 2>/dev/null | tar -tzf - 2>/dev/null | wc -l)"
  if [ "${entries}" -lt 2 ]; then
    echo "error: ${ipk} has an empty data.tar.gz (${entries} entries)." >&2
    exit 1
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

CACHE_DIR="${REPO_DIR}/../downloads"

package_one() {
  local pkgdir="$1" name="$2" want_arch="$3" depends="$4"
  local stage="${WORK}/${name}-${want_arch}"
  rm -rf "${stage}"; mkdir -p "${stage}/CONTROL"

  # The package's rootfs is everything under files/.
  if [ -d "${pkgdir}/files" ]; then
    mkdir -p "${stage}/data"
    cp -a "${pkgdir}/files/." "${stage}/data/"
  else
    mkdir -p "${stage}/data"
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

  # control, with the version stamped in at build time so the .ipk version and
  # the version the console reports cannot disagree.
  sed -e "s/@VERSION@/${VERSION}/g" \
      -e "s/@BUILD@/${BUILD}/g" \
      -e "s/@COMMIT@/${COMMIT}/g" \
      -e "s/@ARCH@/${want_arch}/g" \
      "${pkgdir}/control" > "${stage}/CONTROL/control"
  if [ -n "${depends}" ] && [ "${depends}" != "-" ]; then
    echo "Depends: ${depends//,/, }" >> "${stage}/CONTROL/control"
  fi

  for script in preinst postinst prerm postrm conffiles; do
    [ -f "${pkgdir}/${script}" ] || continue
    cp "${pkgdir}/${script}" "${stage}/CONTROL/${script}"
    [ "${script}" = conffiles ] || chmod 0755 "${stage}/CONTROL/${script}"
  done

  # ── the .ipk container ────────────────────────────────────────────────────
  #
  # A GZIPPED TAR of debian-binary, data.tar.gz and control.tar.gz. NOT an ar
  # archive.
  #
  # Debian's .deb is ar, opkg descends from dpkg, and every description of the
  # ipk format says "ar archive" — so the first version of this built one with
  # `ar -rc`. OpenWrt's opkg does not read that. It installed the packages
  # from our Packages index, recorded them in /usr/lib/opkg/status, wrote an
  # empty .list for each, and extracted no files at all. The image built
  # cleanly, booted, and contained none of ParkezeOS.
  #
  # Nothing warns about this. The only way to see it is to compare against a
  # real OpenWrt package:
  #
  #   $ file uhttpd_2025.07.06_aarch64.ipk
  #   gzip compressed data                     <- what opkg wants
  #   $ file parkeze-base_0.1.0_all.ipk
  #   Debian binary package (format 2.0)       <- what we were producing
  #
  # `tar -tzf` is no help either: bsdtar reads ar archives quite happily and
  # reports success on both. check_ipk_format below uses `file`.
  #
  # --numeric-owner and a fixed mtime keep the output reproducible: two builds
  # of an unchanged tree should produce byte-identical packages, so a rebuilt
  # image can be diffed against a shipped one meaningfully.
  ( cd "${stage}/data" && tar_create "${stage}/data.tar.gz" )
  ( cd "${stage}/CONTROL" && tar_create "${stage}/control.tar.gz" )
  echo "2.0" > "${stage}/debian-binary"

  arch="$(awk -F': *' '/^Architecture:/{print $2}' "${stage}/CONTROL/control")"
  out="${REPO_DIR}/${name}_${VERSION}-${BUILD}_${arch}.ipk"

  # Member order matches what OpenWrt itself produces.
  ( cd "${stage}" && tar_create_files "${out}" debian-binary data.tar.gz control.tar.gz )

  check_ipk_format "${out}"

  echo "  packaged ${name} ${VERSION}-${BUILD} (${arch})"
}

for pkgdir in "${FEED_DIR}"/*/; do
  name="$(basename "${pkgdir}")"
  [ -f "${pkgdir}/control" ] || { echo "skip ${name}: no control file"; continue; }

  # Clear every other build of this package first. BUILD is a timestamp, so
  # without this the repo accumulates one .ipk per build forever, the Packages
  # index lists all of them, and a glob over the directory silently matches
  # several — which is how a stale control file gets read while debugging and
  # sends you looking for a bug that was fixed two builds ago.
  rm -f "${REPO_DIR}/${name}"_*.ipk

  if [ -f "${pkgdir}/arches" ]; then
    while read -r arch depends; do
      case "${arch}" in ''|'#'*) continue ;; esac
      package_one "${pkgdir}" "${name}" "${arch}" "${depends}"
    done < "${pkgdir}/arches"
  else
    package_one "${pkgdir}" "${name}" "" ""
  fi
done

# Index. ImageBuilder reads Packages.gz out of a `src` line in repositories.conf;
# build.sh writes that line, this writes the file it points at.
(
  cd "${REPO_DIR}"
  : > Packages
  for ipk in *.ipk; do
    [ -e "${ipk}" ] || continue
    tmp="$(mktemp -d)"
    tar -xzOf "${ipk}" ./control.tar.gz | tar -xzf - -C "${tmp}"
    cat "${tmp}/control" >> Packages
    printf 'Filename: %s\n' "${ipk}" >> Packages
    printf 'Size: %s\n' "$(wc -c < "${ipk}" | tr -d ' ')" >> Packages
    printf 'SHA256sum: %s\n\n' "$(sha256 "${ipk}")" >> Packages
    rm -rf "${tmp}"
  done
  gzip -9nkf Packages
)

echo "Feed indexed at ${REPO_DIR}"
