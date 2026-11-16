#!/usr/bin/env bash
#
# Check the add-ons are what the images and the repository assume.
#
#   scripts/check-addons.sh
#
# An add-on is a feed/<name>/ directory with an `addon` file. Each rule here
# is one a wrong edit breaks without any build noticing:
#
#   * No board carries pulzr-edge in its image except the RAK7289CV2. The
#     RAK7268CV2s in production must never get Modbus by
#     any automatic path, and a package in a board's list is the most automatic
#     path there is: the plan and the owner both put this guard on the image
#     side. The shared RAK lists are what the RAK7268 boards inherit, so this
#     reads each board's resolved list, not one file.
#   * Every architecture a board that may be offered an add-on runs is in that
#     add-on's arches. apk matches the architecture name exactly, so the
#     GL-SFT1200's mipsel_24kc_24kf was a gap that no build showed. Only for a
#     board with an image: one that needs device support is offered nothing
#     yet, and is checked the day its status says it builds.
#   * The add-on declares the capability it is denied by (Provides:
#     pulzr-cap-<cap>), which is how a later package that depends on a denied
#     capability is refused with it.
#   * Every add-on ships /usr/libexec/pulzr/addon-health/<name>. pulzr-addon
#     reports its answer, and the console counts the add-on installed (its
#     feature word on) while that file is there.
#   * Its feature word is not a board's: a board word means a package group
#     in the image, and the same word from an add-on would gate the same pages
#     on two different things.
#   * Every add-on's keep.d lands in pulzr-base's merged one, so its settings
#     survive an upgrade that finds it missing (scripts/addon-index.sh).
#   * The repository's public key is the only key file in the tree, and it is
#     public.

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOARDS_DIR="${ROOT_DIR}/boards"
FEED_DIR="${ROOT_DIR}/feed"
export BOARDS_DIR

fail=0
bad() { echo "error: $*" >&2; fail=1; }

boards=()
for conf in "${BOARDS_DIR}"/*/board.conf; do
  id="$(basename "$(dirname "${conf}")")"
  [ "${id}" = common ] || boards+=("${id}")
done

# One line per board: its id, its OPENWRT_ARCH, its resolved package list.
board_facts() {
  ( . "${BOARDS_DIR}/$1/board.conf"
    printf '%s\t%s\t%s\t%s\n' "${BOARD_ID}" "${OPENWRT_ARCH:-}" \
      "$(pulzr_packages | sed 's/#.*//' | tr -s '[:space:]' ' ')" "${BOARD_STATUS:-supported}" )
}

facts="$(mktemp)"; trap 'rm -f "${facts}"' EXIT
for b in "${boards[@]}"; do board_facts "${b}" >> "${facts}" || bad "cannot read boards/${b}/board.conf"; done

count=0
for pkgdir in "${FEED_DIR}"/*/; do
  [ -f "${pkgdir}/addon" ] || continue
  name="$(basename "${pkgdir}")"; count=$((count + 1))

  title="" caps="" boards_ok="" feature=""
  eval "$(. "${pkgdir}/addon"; printf 'title=%q caps=%q boards_ok=%q feature=%q' \
            "${ADDON_TITLE:-}" "${ADDON_CAPS:-}" "${ADDON_BOARDS:-}" "${ADDON_FEATURE:-}")"
  [ -n "${title}" ] || bad "${name}/addon has no ADDON_TITLE"
  [ -n "${caps}" ] || bad "${name}/addon has no ADDON_CAPS"
  [ -n "${boards_ok}" ] || bad "${name}/addon has no ADDON_BOARDS"
  [ -x "${pkgdir}/files/usr/libexec/pulzr/addon-health/${name}" ] \
    || bad "${name} has no executable files/usr/libexec/pulzr/addon-health/${name}"
  if [ -n "${feature}" ]; then
    # shellcheck disable=SC1091
    case " $(. "${BOARDS_DIR}/common/board.conf"; echo "${PULZR_FEATURE_WORDS}") " in *" ${feature} "*)
      bad "${name}'s ADDON_FEATURE '${feature}' is a board feature word" ;;
    esac
  fi
  [ -f "${pkgdir}/arches" ] || { bad "${name} is an add-on with no arches file"; continue; }

  for cap in ${caps}; do
    grep -Eq "^Provides:.*(^|[ ,:])pulzr-cap-${cap}([ ,]|$)" "${pkgdir}/control" \
      || bad "${name}/control does not say 'Provides: pulzr-cap-${cap}'"
  done

  while IFS=$'\t' read -r id arch packages status; do
    allowed=0
    if [ "${boards_ok}" = "*" ]; then allowed=1
    else case " ${boards_ok} " in *" ${id} "*) allowed=1 ;; esac; fi

    if [ "${allowed}" = 1 ] && [ "${status}" = supported ]; then
      awk -v a="${arch}" '$1 !~ /^#/ && $1 == a { f = 1 } END { exit !f }' "${pkgdir}/arches" \
        || bad "${name}: ${id} runs ${arch}, which ${name}/arches does not build"
    fi

    # Stands for a production RAK7268CV2: see the header.
    case " ${packages} " in *" ${name} "*)
      if [ "${name}" = pulzr-edge ] && [ "${id}" != rak7289cv2 ]; then
        bad "${id} installs pulzr-edge in its image; only rak7289cv2 may. It is an add-on everywhere else."
      fi
      [ "${allowed}" = 1 ] || bad "${id} installs ${name}, which ADDON_BOARDS does not allow it"
    esac
  done < "${facts}"
done
[ "${count}" -gt 0 ] || bad "no add-ons found; check feed/*/addon"

# What pulzr-base will carry: one addons.caps line per add-on, and each
# add-on's keep.d paths in the merged keep.d.
index="$(mktemp -d)"
if "${ROOT_DIR}/scripts/addon-index.sh" "${FEED_DIR}" "${index}"; then
  for pkgdir in "${FEED_DIR}"/*/; do
    [ -f "${pkgdir}/addon" ] || continue
    name="$(basename "${pkgdir}")"
    grep -q "^${name}"$'\t' "${index}/usr/share/pulzr/addons.caps" \
      || bad "addon-index.sh wrote no addons.caps line for ${name}"
    # shellcheck disable=SC2013  # keep.d paths have no spaces
    for path in $(cat "${pkgdir}"/files/lib/upgrade/keep.d/* 2>/dev/null | grep -v '^[[:space:]]*\(#\|$\)'); do
      grep -qxF "${path}" "${index}/lib/upgrade/keep.d/pulzr-addons" \
        || bad "${name} keeps ${path}, which the merged keep.d/pulzr-addons does not"
    done
  done
else
  bad "scripts/addon-index.sh failed"
fi
rm -rf "${index}"

# The only key material in the tree is the repository's public key.
pub="feed/pulzr-base/files/etc/apk/keys/pulzr-addons.pem"
[ -f "${ROOT_DIR}/${pub}" ] || bad "${pub} is missing"
if command -v openssl >/dev/null 2>&1 && [ -f "${ROOT_DIR}/${pub}" ]; then
  body="$(sed -n '/-----BEGIN/,/-----END/p' "${ROOT_DIR}/${pub}")"
  case "${body}" in *"BEGIN PUBLIC KEY"*) ;; *) bad "${pub} is not a public key" ;; esac
  curve="$(openssl ec -pubin -noout -text <<<"${body}" 2>/dev/null | sed -n 's/^ASN1 OID: //p')"
  [ "${curve}" = prime256v1 ] || bad "${pub} is not an ECDSA P-256 key (got '${curve:-unreadable}')"
fi
# Files only, so a path in a message or a doc about private keys is not one.
if git -C "${ROOT_DIR}" rev-parse --git-dir >/dev/null 2>&1; then
  while IFS= read -r f; do
    grep -q 'PRIVATE KEY' "${ROOT_DIR}/${f}" 2>/dev/null && bad "${f} holds a private key"
  done < <(git -C "${ROOT_DIR}" ls-files -- '*.pem' '*.key')
fi

[ "${fail}" = 0 ] && echo "add-ons ok: ${count} add-on(s), ${#boards[@]} boards"
exit "${fail}"
