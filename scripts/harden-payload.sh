#!/usr/bin/env bash
#
# Make one package's payload ship without its source commentary.
#
#   UCODE=<host ucode> harden-payload.sh <payload-dir>
#
# Everything on a gateway is readable by root and by anyone holding its SD card
# or an image, and every program in feed/ is interpreted, so the code itself
# cannot be hidden. What can go is the source: the comments that explain why
# each decision was made, which are most of the value to anyone studying the
# system.
#
#   ucode       compiled to bytecode with debug info stripped (`ucode -c -s`).
#               No comments, no source text, no line table; what is left is
#               string literals and the names the code itself uses. Templates
#               (files opening with `{%`) are compiled as templates. A ucode
#               executable keeps working: the compiler writes its own
#               `#!/usr/bin/env ucode` line.
#   shell       whole-line comments removed (strip-shell-comments.py), and
#               the same for UCI config files and the sshd config, whose
#               comments are as much rationale as any script's.
#   Lua         whole-line comments removed (strip-lua-comments.py). Only
#               parkeze-rak-power is Lua, for its Modbus library; compiling it the
#               way ucode is would need luac at OpenWrt's exact Lua build,
#               whose number patch changes the bytecode.
#   *.md        removed. Nothing on a gateway reads them.
#
# Run by build-feed.sh for every package unless PARKEZE_DEV=1, so a bench image
# keeps readable source and a release never does.

set -euo pipefail

DATA="${1:?payload dir}"
UCODE="${UCODE:?UCODE must point at scripts/host-ucode.sh output}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ucode's native modules are shared libraries on the gateway and absent here,
# and a static `import` resolves its module when it is compiled. Named here,
# the import is compiled as a load at run time instead, from the gateway's own
# library.
DYNLINK="dynlink=fs,dynlink=math,dynlink=ubus,dynlink=uci,dynlink=uloop,dynlink=nl80211,dynlink=rtnl,dynlink=resolv,dynlink=struct,dynlink=socket,dynlink=zlib,dynlink=digest,dynlink=log,dynlink=io,dynlink=debug"

is_ucode() {
  case "$1" in *.uc) return 0 ;; esac
  head -n1 "$1" 2>/dev/null | grep -q '^#!.*ucode'
}

is_lua() {
  case "$1" in *.lua) return 0 ;; esac
  head -n1 "$1" 2>/dev/null | grep -q '^#!.*lua'
}

is_shell() {
  case "$1" in
    */etc/uci-defaults/*|*/etc/hotplug.d/*|*/lib/preinit/*|*/lib/upgrade/*|*.sh) return 0 ;;
    */etc/config/*|*/sshd_config) return 0 ;;
  esac
  head -n1 "$1" 2>/dev/null | grep -Eq '^#!.*/(sh|ash|bash)( |$)'
}

failed=0
shells=()
luas=()
while IFS= read -r -d '' f; do
  case "${f}" in
    *.md) rm -f "${f}"; continue ;;
  esac
  if is_ucode "${f}"; then
    mode=()
    # Leading whitespace aside, a template opens with a block tag.
    if [ "$(sed -n '/[^[:space:]]/{s/^[[:space:]]*//;p;q;}' "${f}" | cut -c1-2)" = '{%' ]; then
      mode=(-T)
    fi
    out="${f}.ucb"
    if "${UCODE}" ${mode[@]+"${mode[@]}"} -c"${DYNLINK}" -s -o "${out}" "${f}" 2>"${out}.err"; then
      # Over the original rather than renamed, so its mode bits and every path
      # that names it stay as they are.
      cat "${out}" > "${f}"
    else
      echo "error: ${f#"${DATA}"/} does not compile:" >&2
      sed 's/^/  /' "${out}.err" >&2
      failed=1
    fi
    rm -f "${out}" "${out}.err"
  elif is_lua "${f}"; then
    luas+=("${f}")
  elif is_shell "${f}"; then
    shells+=("${f}")
  fi
done < <(find "${DATA}" -type f -print0)

if [ "${#shells[@]}" -gt 0 ]; then
  # A comment removed must not change what the shell parses. Checked against
  # the original: a file that never parsed (a fragment some other script
  # sources) is not this step's to judge.
  before=()
  for f in "${shells[@]}"; do
    if bash -n "${f}" 2>/dev/null; then before+=(1); else before+=(0); fi
  done
  python3 "${HERE}/strip-shell-comments.py" "${shells[@]}"
  for i in "${!shells[@]}"; do
    if [ "${before[$i]}" = 1 ] && ! bash -n "${shells[$i]}" 2>/dev/null; then
      echo "error: stripping comments broke ${shells[$i]#"${DATA}"/}" >&2
      failed=1
    fi
  done
fi

if [ "${#luas[@]}" -gt 0 ]; then
  python3 "${HERE}/strip-lua-comments.py" "${luas[@]}" || failed=1
fi

exit "${failed}"
