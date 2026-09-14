#!/usr/bin/env bash
#
# Write a ParkezeOS image to an SD card.
#
#   ./flash.sh                     pick a board and a card, interactively
#   ./flash.sh rpi4                pick a card for this board
#   ./flash.sh rpi4 /dev/disk4     no prompts except the confirmation
#   ./flash.sh --download rpi4     fetch the latest CI image first
#   ./flash.sh --list-disks        show what is removable and stop
#
# ── THIS SCRIPT DESTROYS A DISK ────────────────────────────────────────────
#
# `dd` onto the wrong device takes a laptop's boot drive with it, and there is
# no undo. So:
#
#   * internal disks are refused outright, not warned about;
#   * the target is never guessed — with one card inserted it is still shown
#     and still confirmed;
#   * confirmation is typing the disk identifier, not pressing y. A reflex "y"
#     is exactly what you produce when you have done this eleven times today.
#
# The guard that matters is the first one. Everything else is manners.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOARDS_DIR="${ROOT_DIR}/boards"
OUT_DIR="${ROOT_DIR}/out"
REPO="parkezesolutions/ParkezeOS"

log()  { printf '\033[36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33m warn\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31merror\033[0m %s\n' "$*" >&2; exit 1; }

# ── boards ──────────────────────────────────────────────────────────────────

board_field() {
  ( . "${BOARDS_DIR}/${1}/board.conf" >/dev/null 2>&1; eval "printf '%s' \"\${$2:-}\"" )
}

sdcard_boards() {
  for dir in "${BOARDS_DIR}"/*/; do
    local board; board="$(basename "${dir}")"
    [ "${board}" = "common" ] && continue
    [ "$(board_field "${board}" BOARD_INSTALL)" = "sdcard" ] || continue
    echo "${board}"
  done
}

# ── finding an image ────────────────────────────────────────────────────────

images_for() {
  # Two layouts to cope with: out/release/ holds the packaged images a CI
  # artifact unpacks into, and out/<board>/ holds raw ImageBuilder output from
  # a local build. Sysupgrade images are excluded — writing one to a blank card
  # produces something that does not boot, and it is the easiest mistake here.
  local board="$1"
  local preferred; preferred="$(board_field "${board}" BOARD_IMAGE_PREFERENCE)"
  {
    find "${OUT_DIR}/release" -maxdepth 1 -name "ParkezeOS-*-${board}.img.gz" 2>/dev/null
    find "${OUT_DIR}/release" -maxdepth 1 -name "ParkezeOS-*-${board}.img.xz" 2>/dev/null
    find "${OUT_DIR}/${board}" -maxdepth 1 -name "*${preferred}*.img.gz" 2>/dev/null
    find "${OUT_DIR}/${board}" -maxdepth 1 -name '*.img.gz' 2>/dev/null
  } | grep -v sysupgrade | awk '!seen[$0]++'
}

download_image() {
  local board="$1"
  command -v gh >/dev/null 2>&1 || die "gh is needed to download images (brew install gh)"

  log "Finding the latest successful build"
  local run
  run="$(gh run list --repo "${REPO}" --workflow build --status success \
         --limit 1 --json databaseId --jq '.[0].databaseId' 2>/dev/null)"
  [ -n "${run}" ] || die "no successful build found in ${REPO}"

  log "Downloading parkezeos-${board} from run ${run}"
  mkdir -p "${OUT_DIR}/release"
  gh run download "${run}" --repo "${REPO}" --name "parkezeos-${board}" \
     --dir "${OUT_DIR}/release" \
    || die "could not download parkezeos-${board} — was that board built?"
}

# ── finding a disk ──────────────────────────────────────────────────────────
#
# Two implementations, because the safety check is the whole point and it is
# completely different on each platform. Neither falls back to a generic
# "list block devices", because a generic listing includes the system disk.

list_disks_macos() {
  # Every whole disk, annotated. `Internal` is the field that decides.
  local id
  for id in $(diskutil list | sed -n 's|^/dev/\(disk[0-9]*\) .*|\1|p'); do
    local info internal removable size name
    info="$(diskutil info -plist "${id}" 2>/dev/null)" || continue
    internal="$(plutil -extract Internal raw - <<<"${info}" 2>/dev/null || echo true)"
    removable="$(plutil -extract RemovableMedia raw - <<<"${info}" 2>/dev/null || echo false)"
    size="$(plutil -extract TotalSize raw - <<<"${info}" 2>/dev/null || echo 0)"
    name="$(plutil -extract MediaName raw - <<<"${info}" 2>/dev/null || echo unknown)"
    [ "${size}" -gt 0 ] 2>/dev/null || continue
    printf '%s\t%s\t%s\t%s\t%s\n' \
      "/dev/${id}" \
      "$(( size / 1000000000 ))GB" \
      "${name}" \
      "$([ "${internal}" = true ] && echo internal || echo external)" \
      "$([ "${removable}" = true ] && echo removable || echo fixed)"
  done
}

list_disks_linux() {
  lsblk -dnpo NAME,SIZE,MODEL,RM,TYPE 2>/dev/null | while read -r name size model rm type; do
    [ "${type}" = "disk" ] || continue
    printf '%s\t%s\t%s\t%s\t%s\n' \
      "${name}" "${size}" "${model:-unknown}" \
      "$([ "${rm}" = "1" ] && echo external || echo internal)" \
      "$([ "${rm}" = "1" ] && echo removable || echo fixed)"
  done
}

list_disks() {
  case "$(uname -s)" in
    Darwin) list_disks_macos ;;
    Linux)  list_disks_linux ;;
    *) die "flashing is supported on macOS and Linux" ;;
  esac
}

show_disks() {
  printf '\n  %-14s %-8s %-28s %s\n' DISK SIZE MEDIA ''
  list_disks | while IFS=$'\t' read -r dev size name where removable; do
    if [ "${where}" = internal ]; then
      printf '  \033[2m%-14s %-8s %-28s %s\033[0m\n' "${dev}" "${size}" "${name}" \
        "internal — will not be offered"
    else
      printf '  %-14s %-8s %-28s \033[32m%s\033[0m\n' "${dev}" "${size}" "${name}" \
        "${removable}"
    fi
  done
  echo
}

# Refuse anything that is not clearly a removable external disk.
assert_safe_target() {
  local target="$1" line
  line="$(list_disks | awk -F'\t' -v d="${target}" '$1 == d')"
  [ -n "${line}" ] || die "${target} is not a whole disk this system reports.
       Pass the whole disk (/dev/disk4), not a partition (/dev/disk4s1)."

  local where removable size name
  size="$(cut -f2 <<<"${line}")"; name="$(cut -f3 <<<"${line}")"
  where="$(cut -f4 <<<"${line}")"; removable="$(cut -f5 <<<"${line}")"

  if [ "${where}" = internal ]; then
    die "${target} is an internal disk (${name}, ${size}). Refusing.
       If this really is the card reader, it is not reporting itself as
       external — use the manufacturer's tool rather than making this script
       trust you."
  fi

  # An external disk that is not removable media is a USB SSD or a backup
  # drive. Possible to want, easy to hit by accident, so it takes a flag.
  if [ "${removable}" != removable ] && [ "${ALLOW_FIXED:-0}" != 1 ]; then
    die "${target} is external but not removable media (${name}, ${size}).
       That is usually a USB drive rather than a card reader. If you are sure:
       ALLOW_FIXED=1 $0 ..."
  fi
}

unmount_disk() {
  case "$(uname -s)" in
    Darwin) diskutil unmountDisk "$1" >/dev/null || die "could not unmount $1" ;;
    Linux)
      # Every partition of it, ignoring the ones that were not mounted.
      lsblk -lnpo NAME "$1" | tail -n +2 | while read -r part; do
        mountpoint -q "${part}" 2>/dev/null && sudo umount "${part}" || true
      done ;;
  esac
}

# macOS writes an order of magnitude faster to the raw device.
raw_device() {
  case "$(uname -s)" in
    Darwin) echo "${1/\/dev\/disk//dev/rdisk}" ;;
    *)      echo "$1" ;;
  esac
}

# ── writing ─────────────────────────────────────────────────────────────────

write_image() {
  local image="$1" target="$2"
  local raw; raw="$(raw_device "${target}")"

  log "Unmounting ${target}"
  unmount_disk "${target}"

  log "Writing $(basename "${image}")"
  echo "    this takes a few minutes and the card's light will be busy throughout"

  # gunzip streams into dd so no decompressed copy is ever written to disk.
  # `status=progress` is GNU/`bs=4m` BSD; both are handled rather than
  # assuming coreutils.
  local decompress
  case "${image}" in
    *.xz) decompress="xz -dc" ;;
    *.gz) decompress="gunzip -c" ;;
    *)    decompress="cat" ;;
  esac

  if [ "$(uname -s)" = Darwin ]; then
    ${decompress} "${image}" | sudo dd of="${raw}" bs=4m 2>&1 | tail -3
  else
    ${decompress} "${image}" | sudo dd of="${raw}" bs=4M conv=fsync status=progress 2>&1 | tail -3
  fi

  log "Flushing"
  sync
  case "$(uname -s)" in
    Darwin) diskutil eject "${target}" >/dev/null 2>&1 || true ;;
  esac
}

# ── the interactive bits ────────────────────────────────────────────────────

choose() {
  # choose <prompt> <option>... -> echoes the chosen option
  local prompt="$1"; shift
  local options=("$@")
  [ "${#options[@]}" -eq 1 ] && { echo "${options[0]}"; return; }
  {
    echo
    local i=1
    for option in "${options[@]}"; do printf '  %d) %s\n' "${i}" "${option}"; i=$((i+1)); done
    echo
  } >&2
  local pick
  read -rp "${prompt} [1-${#options[@]}]: " pick
  [[ "${pick}" =~ ^[0-9]+$ ]] && [ "${pick}" -ge 1 ] && [ "${pick}" -le "${#options[@]}" ] \
    || die "not a choice"
  echo "${options[$((pick-1))]}"
}

# ── main ────────────────────────────────────────────────────────────────────

DOWNLOAD=0
case "${1:-}" in
  --list-disks) show_disks; exit 0 ;;
  --download)   DOWNLOAD=1; shift ;;
  # Printed from the header comment rather than a duplicate usage string, so
  # the two cannot disagree. Stops at the first line that is not a comment,
  # instead of a hardcoded line number that drifts every time the header grows.
  -h|--help)
    awk 'NR>1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
    exit 0 ;;
esac

BOARD="${1:-}"
TARGET="${2:-}"

boards=()
while IFS= read -r b; do boards+=("${b}"); done < <(sdcard_boards)
[ "${#boards[@]}" -gt 0 ] || die "no boards install from an SD card"

if [ -z "${BOARD}" ]; then
  BOARD="$(choose "Which board" "${boards[@]}")"
fi

[ -d "${BOARDS_DIR}/${BOARD}" ] || die "unknown board '${BOARD}'"

install_method="$(board_field "${BOARD}" BOARD_INSTALL)"
if [ "${install_method}" != sdcard ]; then
  die "${BOARD} does not install from an SD card (BOARD_INSTALL=${install_method}).
       It boots from soldered flash and is updated through its own upgrade
       path — see devices/README.md."
fi

[ "${DOWNLOAD}" = 1 ] && download_image "${BOARD}"

candidates=()
while IFS= read -r f; do candidates+=("${f}"); done < <(images_for "${BOARD}" || true)
if [ "${#candidates[@]}" -eq 0 ]; then
  die "no image for ${BOARD}.
       Build one:     ./build.sh ${BOARD}
       Or fetch one:  ./flash.sh --download ${BOARD}
       Or skip this script entirely and use Raspberry Pi Imager —
       see docs/flashing.md."
fi

IMAGE="${candidates[0]}"
if [ "${#candidates[@]}" -gt 1 ] && [ -z "${TARGET}" ]; then
  IMAGE="$(choose "Which image" "${candidates[@]}")"
fi

# ── the disk ────────────────────────────────────────────────────────────────

if [ -z "${TARGET}" ]; then
  show_disks
  available=()
  while IFS=$'\t' read -r dev _ _ where _; do
    [ "${where}" = external ] && available+=("${dev}")
  done < <(list_disks)

  [ "${#available[@]}" -gt 0 ] \
    || die "no external disk found. Insert the card and run this again."

  # Deliberately still asked with exactly one candidate: "the only card
  # inserted" and "the card you meant" are not the same claim.
  TARGET="$(choose "Which disk" "${available[@]}")"
fi

assert_safe_target "${TARGET}"

# ── confirm ─────────────────────────────────────────────────────────────────

info="$(list_disks | awk -F'\t' -v d="${TARGET}" '$1 == d')"
cat <<EOF

  Board   ${BOARD}
  Image   $(basename "${IMAGE}")
  Disk    ${TARGET}  ($(cut -f3 <<<"${info}"), $(cut -f2 <<<"${info}"))

  Everything on ${TARGET} will be destroyed.

EOF

read -rp "  Type the disk identifier to continue ($(basename "${TARGET}")): " typed
[ "${typed}" = "$(basename "${TARGET}")" ] || die "that does not match; nothing was written"

write_image "${IMAGE}" "${TARGET}"

cat <<EOF

$(printf '\033[32m==>\033[0m') Done. Put the card in the ${BOARD} and power it on.

  First boot takes a minute or two while it generates its identity and its
  console certificate.

  Console     https://192.168.61.1/    (plug a laptop into the ethernet port)
  WiFi        join "parkeze_<mac>" — it is open until the gateway is adopted
  Serial      115200 8N1 on the GPIO header; the banner prints the console
              address and the one-time password

  The gateway shows a claim code on all three. Scan it, or enter it at
  https://parkeze.net/adopt to adopt the gateway — it finishes on its own.

EOF
