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

# ── COMPILE EACH FILE THE WAY ITS LOADER WILL ───────────────────────────────
#
# This used to pass -cmodule to everything, which is how a console that could
# never start shipped in every image we built. uhttpd does not load its handler
# as a module: it compiles it as a TEMPLATE, and the lib files it pulls in with
# loadfile() are plain raw-mode scripts. Validating them as ES modules accepted
# `export` and `import` that the device rejects outright, so CI was green while
# uhttpd refused to start with "declares no handle_request() callback".
#
# So the mode is chosen per file, matching the loader:
#
#   api/index.uc     template mode. Compiled without -R, like uhttpd does.
#   lib/*.uc         raw mode, no module flag. `export` here is a syntax error,
#                    which is the point — it is one on the device too.
#   everything else  raw mode. Standalone ucode programs with a shebang.
fail=0
count=0
while IFS= read -r file; do
  count=$((count + 1))
  # index.uc is a ucode TEMPLATE, because that is how uhttpd compiles it: the
  # code lives inside {% %} and anything outside is text. Rather than depend on
  # which way a given ucode build defaults (the CLI has flipped between raw and
  # template as the default, so -R/-T is not portable across versions), the
  # wrapper is stripped and the code inside is compiled in raw mode. That tests
  # the thing that matters and behaves the same on every ucode.
  target="${file}"
  case "${file}" in
    */console/api/index.uc)
      target="$(mktemp)"
      sed -e '1{/^{%$/d;}' -e '${/^%}$/d;}' "${file}" > "${target}" ;;
  esac
  set -- -R -L "${STUBS}/*.uc" -o /dev/null "${target}"
  if ! out="$("${UCODE}" "$@" 2>&1)"; then
    echo "FAIL ${file}"
    echo "${out}" | sed 's/^/     /'
    fail=$((fail + 1))
  elif [ -n "${out}" ]; then
    echo "WARN ${file}"
    echo "${out}" | sed 's/^/     /'
  fi
  [ "${target}" = "${file}" ] || rm -f "${target}"
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

# ── SCOPE ───────────────────────────────────────────────────────────────────
#
# ucode does not hoist function declarations, and a forward reference throws at
# runtime rather than failing to compile. Separate script because it needs real
# parsing; see its docstring.
if command -v python3 >/dev/null 2>&1; then
  if ! python3 "$(dirname "$0")/check-ucode-scope.py"; then
    fail=$((fail + 1))
  fi
else
  echo "WARN python3 not found — skipping the ucode scope check"
fi

# ── THE SHAPE uhttpd REQUIRES ───────────────────────────────────────────────
#
# Compiling is not enough. Every shape that fails on the device also compiles
# cleanly — that is exactly why this went unnoticed — so the one thing uhttpd
# actually looks for is asserted directly: a bare assignment to an undeclared
# `handle_request`, which is what lands in the VM global scope it reads.
HANDLER="feed/parkeze-console/files/usr/share/parkeze/console/api/index.uc"
if [ -f "${HANDLER}" ]; then
  if ! head -c 4 "${HANDLER}" | grep -q '{%'; then
    echo "FAIL ${HANDLER}"
    echo "     must open with '{%' — uhttpd compiles it as a template, and an"
    echo "     unwrapped file defines nothing at all."
    fail=$((fail + 1))
  fi
  if ! grep -qE '^handle_request[[:space:]]*=' "${HANDLER}"; then
    echo "FAIL ${HANDLER}"
    echo "     must assign handle_request as a bare global:"
    echo "         handle_request = function(env) { ... };"
    echo "     'export function', 'function' and 'return { handle_request }'"
    echo "     all compile and all leave uhttpd reporting that the handler"
    echo "     declares no handle_request() callback."
    fail=$((fail + 1))
  fi
fi

# lib/*.uc are loaded with loadfile(), so they must end in a returned object
# rather than exports.
for lib in feed/parkeze-console/files/usr/share/parkeze/console/lib/*.uc; do
  [ -f "${lib}" ] || continue
  if grep -q '^export ' "${lib}"; then
    echo "FAIL ${lib}"
    echo "     'export' is a syntax error where loadfile() compiles this."
    echo "     End the file with: return { name, other };"
    fail=$((fail + 1))
  fi
done

echo
if [ "${fail}" -gt 0 ]; then
  echo "${fail} of ${count} ucode files failed to compile"
  exit 1
fi
echo "${count} ucode files compile cleanly"
