#!/bin/sh
#
# No feed script calls a command the image does not have.
#
# This exists because `timeout` is not in this BusyBox and there is no
# coreutils, and three scripts called it anyway: GPS detection (which then
# documented the lesson), GPS reads, and the report's stats section. Each one
# failed as "timeout: not found" inside a `$(...)` that may come back empty,
# so nothing errored: GPS read nothing on every board and every report sent
# `"stats":{}`. Tests on a build host find the host's own `timeout` and pass.
#
# Use pulzr-timeout (pulzr-base) instead. A command the image lacks for the
# same reason goes in MISSING with what to use instead.

set -eu

MISSING='timeout:pulzr-timeout'

# Shell scripts only (a `#!/bin/sh` first line or a .sh name): ucode and Lua
# say "timeout" in nftables rules and comments, which call nothing.
scripts="$(find feed -type f -path '*/files/*' -exec awk '
    FNR == 1 { if ($0 ~ /^#!\/bin\/sh/ || FILENAME ~ /\.sh$/) print FILENAME; nextfile }' {} +)"

fail=0
for entry in ${MISSING}; do
    name="${entry%%:*}" instead="${entry#*:}"
    # In command position: at the start of a line or after $( ` | ; & && ||,
    # and not in a comment.
    # shellcheck disable=SC2086
    hits="$(grep -nE "(^|\\\$\(|[\`|;&])[[:space:]]*${name}[[:space:]]+[^[:space:]]" ${scripts} \
        | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)"
    if [ -n "${hits}" ]; then
        echo "${name} is not on the image; use ${instead}:" >&2
        echo "${hits}" >&2
        fail=1
    fi
done

[ "${fail}" = 0 ] && echo "no calls to commands the image lacks"
exit "${fail}"
