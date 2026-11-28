# The WiFi uplinks, for every script that picks a free link to send on.
#
#   . /usr/share/pulzr/wifi.sh
#
# There used to be one, wwifi, and every script named it. A gateway with two
# radios can have two:
#
#   wwifi    the station the WiFi page joins (wireless.pulzr_sta)
#   wwifi2   a second radio's station, joined from the radios page
#            (wireless.pulzr_sta2), on the same network or another one
#
# Two because changing the radio the uplink is on used to rewrite the one
# station: the old radio let go of the network before the new one had joined
# it, and the tunnel spent that gap on no uplink. With a second station the
# new radio joins beside the old one, pulzr-wifi-uplink proves it, and only
# then does the order move traffic onto it.
#
# A WiFi uplink is usable once pulzr-wifi-uplink has seen it reach the
# internet: a guest network has a gateway before anybody has signed in, and
# traffic pinned there went into its sign-in page. The order is the route
# metric's, which is pulzr-uplinks' order, as in wired.sh.

. /lib/functions/network.sh

# The WiFi uplink interfaces, best metric first, one per line.
wifi_ifaces() {
    local iface
    for iface in wwifi wwifi2; do
        [ "$(uci -q get "network.${iface}")" = interface ] || continue
        echo "$(uci -q get "network.${iface}.metric" || echo 30) ${iface}"
    done | sort -n | cut -d' ' -f2
}

# "<gateway> <device> <interface>" of the first usable WiFi uplink.
wifi_gateway() {
    local iface gw dev
    network_flush_cache
    for iface in $(wifi_ifaces); do
        /usr/sbin/pulzr-wifi-uplink usable "${iface}" 2>/dev/null || continue
        network_get_gateway gw "${iface}" || continue
        network_get_device dev "${iface}" || continue
        [ -n "${gw}" ] && [ -n "${dev}" ] || continue
        echo "${gw} ${dev} ${iface}"
        return 0
    done
    return 1
}
