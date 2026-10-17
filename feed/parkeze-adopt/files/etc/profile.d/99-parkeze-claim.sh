# Show the claim QR on an interactive login, while this gateway is unadopted
# or its claim was revoked and a new one waits to be adopted.
#
# This is the "over SSH" half of one-touch provisioning: somebody who has got
# as far as a shell should not then have to find out that a `parkeze-claim`
# command exists. An adopted gateway prints nothing — the banner is there to
# get an install finished, not to decorate every login forever.

case "$-" in *i*) ;; *) return ;; esac

[ -f /etc/parkeze/board.conf ] || return
command -v qrencode >/dev/null 2>&1 || return

if [ "$(uci -q get parkeze.adoption.state)" = "adopted" ]; then
    parkeze-claim reclaiming >/dev/null 2>&1 || return
    printf '\n\033[1m  %s\033[0m\n' "This gateway's claim was revoked."
else
    printf '\n\033[1m  This gateway is not adopted yet.\033[0m\n'
fi
printf '  Scan to claim it, or open the console at https://%s/\n\n' \
    "$(uci -q get network.console.ipaddr 2>/dev/null || echo 192.168.61.1)"

parkeze-claim qr --ascii 2>/dev/null | sed 's/^/  /'

printf '\n  Code: \033[1m%s\033[0m\n\n' \
    "$(parkeze-claim status 2>/dev/null | jsonfilter -e '@.claimId' 2>/dev/null)"
