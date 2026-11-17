# /lib/functions/network.sh for scripts/test-wifi-uplink.sh: netifd's view of
# wwifi from the environment ($WIFI_DEV, $WIFI_GW, $WIFI_DNS).
network_get_device() { [ -n "${WIFI_DEV}" ] || return 1; eval "$1=\${WIFI_DEV}"; }
network_get_gateway() { [ -n "${WIFI_GW}" ] || return 1; eval "$1=\${WIFI_GW}"; }
network_get_dnsserver() { eval "$1=\${WIFI_DNS}"; [ -n "${WIFI_DNS}" ]; }
