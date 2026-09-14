#!/usr/bin/env bash
#
# Compile every .uc file in the feed and report syntax errors.
#
#   UCODE=/path/to/ucode scripts/check-ucode.sh
#
# The console is written in ucode, which is not installed on a Mac and is not
# something CI gets for free. Without this, a typo in a console module is only
# discovered by flashing a gateway and watching the API return 500 — a
# twenty-minute round trip for a missing brace.
#
# The native modules (fs, uci, ubus, digest) resolve to the stubs in
# scripts/ucode-stubs/, which declare the real modules' exports. So this checks
# syntax, module structure, *and* that every imported name actually exists —
# provided the stubs are kept honest. It does not check argument counts or
# runtime behaviour.

set -uo pipefail

UCODE="${UCODE:-ucode}"
command -v "${UCODE}" >/dev/null 2>&1 || {
  echo "ucode not found. Build it:"
  echo "  git clone --depth 1 https://github.com/jow-/ucode && cd ucode"
  echo "  cmake -B build -DFS_SUPPORT=ON && cmake --build build"
  echo "  UCODE=\$PWD/build/ucode scripts/check-ucode.sh"
  exit 2
}

# Stub modules stand in for the native ones. See scripts/ucode-stubs/README.md.
STUBS="$(cd "$(dirname "$0")/ucode-stubs" && pwd)"

# Confirm the interpreter actually runs before blaming the source. A ucode
# built from source links libucode.so beside it; a binary copied or restored
# without that library starts nowhere, and reporting it once here beats
# reporting the same loader error against every file in the feed.
if ! "${UCODE}" -e 'print("")' >/dev/null 2>&1; then
  echo "error: ${UCODE} cannot run." >&2
  "${UCODE}" -e 'print("")' 2>&1 | sed 's/^/  /' >&2
  echo "  A source build needs libucode.so alongside the binary." >&2
  exit 2
fi

fail=0
count=0
while IFS= read -r file; do
  count=$((count + 1))
  if ! out="$("${UCODE}" -R -cmodule -L "${STUBS}/*.uc" -o /dev/null "${file}" 2>&1)"; then
    echo "FAIL ${file}"
    echo "${out}" | sed 's/^/     /'
    fail=$((fail + 1))
  elif [ -n "${out}" ]; then
    echo "WARN ${file}"
    echo "${out}" | sed 's/^/     /'
  fi
done < <(
  {
    find feed -name '*.uc'
    # Standalone ucode programs live in usr/sbin with no .uc suffix and are
    # identified by their shebang. parkeze-figlet is one.
    find feed -type f -path '*/usr/sbin/*' -print0 \
      | while IFS= read -r -d '' f; do
          head -c 32 "$f" | grep -q ucode && printf '%s\n' "$f"
        done
  } | sort -u
)

echo
if [ "${fail}" -gt 0 ]; then
  echo "${fail} of ${count} ucode files failed to compile"
  exit 1
fi
echo "${count} ucode files compile cleanly"
