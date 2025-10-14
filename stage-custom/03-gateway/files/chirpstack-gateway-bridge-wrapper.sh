#!/bin/bash
# Wrapper script to substitute MQTT credentials before starting ChirpStack Gateway Bridge

# Load credentials
source /home/parkeze/.gateway-credentials.env

# Create runtime config with substituted credentials
sed -e "s/PLACEHOLDER_MQTT_GATEWAY_ID/${MQTT_GATEWAY_ID}/" \
    -e "s/PLACEHOLDER_MQTT_PASSWORD/${MQTT_PASSWORD}/" \
    /etc/chirpstack-gateway-bridge/chirpstack-gateway-bridge.toml.template \
    > /tmp/chirpstack-gateway-bridge.toml

# Start ChirpStack Gateway Bridge with the runtime config
exec /usr/local/bin/chirpstack-gateway-bridge -c /tmp/chirpstack-gateway-bridge.toml
