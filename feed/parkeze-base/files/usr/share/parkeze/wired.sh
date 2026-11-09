# The wired uplinks, for every script that picks a free link to send on.
#
#   . /usr/share/parkeze/wired.sh
#
# There used to be one, `wan`, and every script named it. parkeze-ports lets
# any port, or a VLAN on one, be an uplink, so a gateway can have several:
#
#   wan            the board's uplink port, untagged (PARKEZE_PORT_IFACE)
#   wan_<device>   any other: wan_lan1, wan_wan_20 for VLAN 20 on the wan port
#
# and none at all when that port serves devices and nothing else is an
# uplink. So nothing names wan any more; it asks here, as it asks
# cellular.sh for the billed ones.
#
# The order is the route metric's, which is parkeze-uplinks' order: the
# first usable one here is the one the main table sends on.

. /lib/functions/network.sh

# The wired uplink interfaces, best metric first, one per line.
wired_ifaces() {
    uci -q show network | sed -nE 's/^network\.(wan|wan_[A-Za-z0-9_]+)=interface$/\1/p' \
        | while read -r iface; do
            [ "$(uci -q get "network.${iface}.disabled")" = 1 ] && continue
            echo "$(uci -q get "network.${iface}.metric" || echo 10) ${iface}"
        done | sort -n | cut -d' ' -f2
}

# Whether the name is a wired uplink's.
is_wired_iface() {
    case "$1" in wan|wan_*) return 0 ;; esac
    return 1
}

# "<gateway> <device> <interface>" of the first wired uplink with a default
# route that parkeze-uplinks has not seen carry nothing: a cable to a router
# whose own internet is gone keeps its lease, and traffic pinned to it would
# wait there instead of moving on.
wired_gateway() {
    local iface gw dev
    network_flush_cache
    for iface in $(wired_ifaces); do
        if [ -x /usr/sbin/parkeze-uplinks ]; then
            /usr/sbin/parkeze-uplinks usable "${iface}" 2>/dev/null || continue
        fi
        network_get_gateway gw "${iface}" || continue
        network_get_device dev "${iface}" || continue
        [ -n "${gw}" ] && [ -n "${dev}" ] || continue
        echo "${gw} ${dev} ${iface}"
        return 0
    done
    return 1
}
