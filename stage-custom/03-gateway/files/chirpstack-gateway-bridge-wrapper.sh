#!/bin/bash
# Wrapper script to substitute MQTT credentials before starting ChirpStack Gateway Bridge

# Load credentials
source /home/parkeze/.gateway-credentials.env

# Build MQTT client ID as parkeze_<MAC> with no colons
get_gateway_mac_no_colons() {
    local iface mac mac_hex
    for iface in eth0 wlan0; do
        if [[ -r "/sys/class/net/${iface}/address" ]]; then
            mac=$(tr -d '\n' < "/sys/class/net/${iface}/address")
            if [[ "$mac" =~ ^([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}$ ]]; then
                mac_hex="${mac//:/}"
                mac_hex="${mac_hex^^}"
                echo "${mac_hex}"
                return 0
            fi
        fi
    done
    return 1
}

MAC_NO_COLONS="$(get_gateway_mac_no_colons)"
if [[ -z "${MAC_NO_COLONS}" ]]; then
    echo "Failed to determine Gateway MAC from eth0/wlan0" >&2
    exit 1
fi

MQTT_CLIENT_ID="parkeze_${MAC_NO_COLONS}"

# Create runtime config with substituted credentials
sed -e "s|PLACEHOLDER_MQTT_SERVER|${MQTT_SERVER}|" \
    -e "s/PLACEHOLDER_MQTT_GATEWAY_ID/${MQTT_GATEWAY_ID}/" \
    -e "s/PLACEHOLDER_MQTT_PASSWORD/${MQTT_PASSWORD}/" \
    -e "s/PLACEHOLDER_MQTT_CLIENT_ID/${MQTT_CLIENT_ID}/" \
    -e "s/PLACEHOLDER_REGION/${REGION}/g" \
    /etc/chirpstack-gateway-bridge/chirpstack-gateway-bridge.toml.template \
    > /tmp/chirpstack-gateway-bridge.toml

# Start ChirpStack Gateway Bridge with the runtime config
exec /usr/local/bin/chirpstack-gateway-bridge -c /tmp/chirpstack-gateway-bridge.toml
