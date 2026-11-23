#!/bin/sh
# Prints the .config lines that build OpenWrt's busybox with the release's
# configuration and the shell's login banner compiled out
# (FEATURE_SH_EXTRA_QUIET). Run in an OpenWrt tree whose .config has been
# through `make defconfig` once without them; append the output and run
# defconfig again.
#
# Why the copy: BUSYBOX_CUSTOM swaps the recipe from the release's
# BUSYBOX_DEFAULT_* values to BUSYBOX_CONFIG_* ones, and the latter do not all
# default to the former (PIDOF and LOGIN_SESSION_AS_CHILD came out unset on
# 24.10, which sdk/build.sh caught). Copying every DEFAULT into its CONFIG
# makes the custom build the release's, except for the one line set here.
#
#   scripts/busybox-quiet-config.sh [.config]
set -eu
config="${1:-.config}"
[ -f "${config}" ] || { echo "no ${config}" >&2; exit 1; }
grep -q '^CONFIG_BUSYBOX_DEFAULT_' "${config}" \
  || { echo "${config} has no BUSYBOX_DEFAULT_ values: run make defconfig first" >&2; exit 1; }
echo 'CONFIG_BUSYBOX_CUSTOM=y'
sed -nE \
  -e 's/^CONFIG_BUSYBOX_DEFAULT_([A-Za-z0-9_]+)=(.*)$/CONFIG_BUSYBOX_CONFIG_\1=\2/p' \
  -e 's/^# CONFIG_BUSYBOX_DEFAULT_([A-Za-z0-9_]+) is not set$/# CONFIG_BUSYBOX_CONFIG_\1 is not set/p' \
  "${config}" | grep -v 'BUSYBOX_CONFIG_FEATURE_SH_EXTRA_QUIET[= ]' || true
echo 'CONFIG_BUSYBOX_CONFIG_FEATURE_SH_EXTRA_QUIET=y'
