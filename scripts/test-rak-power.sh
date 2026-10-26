#!/usr/bin/env bash
#
# parkeze-rak-power against a fake bus, then against a simulated RAK power board.
#
#   scripts/test-rak-power.sh             both
#   RAK_POWER_UNIT_ONLY=1 scripts/...     the fake bus only: no compiler, no pymodbus
#
# No bench unit has answered on this bus, so this is what says the watchdog is
# fed with the right frame. The simulated half runs the real library: the
# lua-libmodbus release OpenWrt 24.10 packages, built here from the same
# tarball (its hash is OpenWrt's PKG_HASH), linked to the host's libmodbus,
# talking over a pty pair to pymodbus, which frames and decodes everything
# independently. See scripts/rak-power-test/simulator.py.
#
# Needs: Lua 5.1 or LuaJIT and, for the simulated half, a C compiler, curl,
# libmodbus with its headers (apt libmodbus-dev, brew libmodbus), and
# python3 with venv. The host's libmodbus is newer than OpenWrt's 3.1.8 on
# most machines; the API this uses has not changed since 3.1.0.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERE="${ROOT_DIR}/scripts/rak-power-test"
WORK="${ROOT_DIR}/.build/rak-power-test"
LUA_PATH_FEED="${ROOT_DIR}/feed/parkeze-rak-power/files/usr/lib/lua/?.lua"

LUA_LIBMODBUS_URL="https://codeload.github.com/etactica/lua-libmodbus/tar.gz/v0.7"
LUA_LIBMODBUS_SHA256="70369f4c4e36421095bf00dcee36c633b4284eaa79bcfdfd230bfefb27acefda"
LUA_CJSON_URL="https://kyne.au/~mark/software/download/lua-cjson-2.1.0.tar.gz"
LUA_CJSON_SHA256="51bc69cd55931e0cba2ceae39e9efa2483f4292da3a88a1ed470eda829f6c778"
PYMODBUS="pymodbus==3.6.9"
PYSERIAL="pyserial==3.5"

die() { echo "error: $*" >&2; exit 2; }

LUA=""
for candidate in lua5.1 luajit; do
  command -v "${candidate}" >/dev/null 2>&1 && { LUA="${candidate}"; break; }
done
[ -n "${LUA}" ] || die "needs lua5.1 or luajit: OpenWrt's Lua is 5.1, and 5.2+ would test a different language"

run_lua() {
  "${LUA}" -e "package.path='${LUA_PATH_FEED};'..package.path; package.cpath='${WORK}/lib/?.so;'..package.cpath" \
    "${HERE}/test.lua"
}

if [ "${RAK_POWER_UNIT_ONLY:-0}" = 1 ]; then
  run_lua
  exit $?
fi

# ── lua-libmodbus and lua-cjson, as OpenWrt builds them ─────────────────────

case "${LUA}" in
  luajit) lua_cflags="$(pkg-config --cflags luajit)" ;;
  *)      lua_cflags="$(pkg-config --cflags lua5.1 2>/dev/null || echo -I/usr/include/lua5.1)" ;;
esac
shared="-shared"
[ "$(uname)" = Darwin ] && shared="-bundle -undefined dynamic_lookup"

mkdir -p "${WORK}/src" "${WORK}/lib"
if [ ! -f "${WORK}/lib/libmodbus.so" ]; then
  tarball="${WORK}/src/lua-libmodbus-0.7.tar.gz"
  [ -f "${tarball}" ] || curl -fsSL -o "${tarball}" "${LUA_LIBMODBUS_URL}"
  got="$( (sha256sum "${tarball}" 2>/dev/null || shasum -a 256 "${tarball}") | cut -d' ' -f1)"
  [ "${got}" = "${LUA_LIBMODBUS_SHA256}" ] || die "lua-libmodbus 0.7 hash is ${got}, not OpenWrt's"
  rm -rf "${WORK}/src/lua-libmodbus-0.7"
  mkdir -p "${WORK}/src/lua-libmodbus-0.7"
  tar xzf "${tarball}" -C "${WORK}/src/lua-libmodbus-0.7" --strip-components=1

  modbus_cflags="$(pkg-config --cflags libmodbus)" || die "no libmodbus (apt libmodbus-dev, brew libmodbus)"
  modbus_libs="$(pkg-config --libs libmodbus)"
  # The source includes <modbus/modbus.h>; pkg-config points into that
  # directory, so its parent goes on the path too.
  modbus_parent="$(pkg-config --variable=includedir libmodbus)"
  # shellcheck disable=SC2086
  cc -O2 -std=gnu99 -fPIC ${shared} ${lua_cflags} ${modbus_cflags} -I"${modbus_parent}" \
    -o "${WORK}/lib/libmodbus.so" "${WORK}/src/lua-libmodbus-0.7/lua-libmodbus.c" ${modbus_libs}
fi

# lua-cjson, for the daemon's entry point, which writes its record with it.
# OpenWrt's one patch adds Lua 5.2+ support, which 5.1 does not need.
if [ ! -f "${WORK}/lib/cjson.so" ]; then
  tarball="${WORK}/src/lua-cjson-2.1.0.tar.gz"
  [ -f "${tarball}" ] || curl -fsSL -o "${tarball}" "${LUA_CJSON_URL}"
  got="$( (sha256sum "${tarball}" 2>/dev/null || shasum -a 256 "${tarball}") | cut -d' ' -f1)"
  [ "${got}" = "${LUA_CJSON_SHA256}" ] || die "lua-cjson 2.1.0 hash is ${got}, not OpenWrt's"
  rm -rf "${WORK}/src/lua-cjson-2.1.0"
  tar xzf "${tarball}" -C "${WORK}/src"
  src="${WORK}/src/lua-cjson-2.1.0"
  # shellcheck disable=SC2086
  cc -O2 -fPIC ${shared} ${lua_cflags} -o "${WORK}/lib/cjson.so" \
    "${src}/lua_cjson.c" "${src}/strbuf.c" "${src}/fpconv.c"
fi

# ── pymodbus ────────────────────────────────────────────────────────────────

if [ ! -x "${WORK}/venv/bin/python" ]; then
  python3 -m venv "${WORK}/venv"
  "${WORK}/venv/bin/pip" install --quiet "${PYMODBUS}" "${PYSERIAL}"
fi

# ── the bus ─────────────────────────────────────────────────────────────────

SIM="$(mktemp -d)"
"${WORK}/venv/bin/python" "${HERE}/simulator.py" "${SIM}" > "${SIM}/simulator.log" 2>&1 &
SIM_PID=$!
trap 'kill "${SIM_PID}" 2>/dev/null; wait "${SIM_PID}" 2>/dev/null; rm -rf "${SIM}"' EXIT

for _ in $(seq 1 50); do
  [ -s "${SIM}/port" ] && break
  kill -0 "${SIM_PID}" 2>/dev/null || { cat "${SIM}/simulator.log" >&2; die "the simulator did not start"; }
  sleep 0.1
done
[ -s "${SIM}/port" ] || die "the simulator never opened its port"
# Its server is listening a moment after the port file appears.
sleep 0.5

RAK_POWER_SIM="${SIM}" RAK_POWER_MAIN="${ROOT_DIR}/feed/parkeze-rak-power/files/usr/sbin/parkeze-rak-power" run_lua || { echo "--- simulator log" >&2; tail -n 30 "${SIM}/simulator.log" >&2; exit 1; }
