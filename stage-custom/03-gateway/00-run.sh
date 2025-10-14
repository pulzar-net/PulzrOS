#!/bin/bash -e

# Install and configure LoRaWAN gateway services for RAK5146
on_chroot << EOF

echo "Installing LoRaWAN gateway packages..."

# Update package index
apt-get update

# Install git and dependencies
apt-get install -y git

echo "Installing RAKWireless gateway software for RAK5146 USB..."

# Clone RAK common gateway installer
cd /opt
git clone https://github.com/RAKWireless/rak_common_for_gateway.git
cd rak_common_for_gateway

# Patch the installer to always respect --chirpstack=not_install flag
# The installer forces ChirpStack=1 on unknown Pi models (chroot returns model 255)
# This removes that override so our flag works
sed -i '/if \[ \$rpi_model -ne 3 \] && \[ \$rpi_model -ne 4 \]; then/,/fi/d' install.sh

# Patch sysconf/install.sh to skip timedatectl in chroot (fails during build)
sed -i 's/timedatectl set-timezone UTC/# timedatectl set-timezone UTC/' sysconf/install.sh
sed -i 's/timedatectl set-ntp true/# timedatectl set-ntp true/' sysconf/install.sh

# Run automated installation for RAK5146 USB (option 10)
# This installs the packet forwarder and all dependencies
# Skip ChirpStack installation since we'll install our own version
echo "10" | ./install.sh --chirpstack=not_install

echo "Configuring packet forwarder for localhost..."
# RAK installer creates configuration at /opt/ttn-gateway/packet_forwarder/lora_pkt_fwd/
# Update local_conf.json to forward to localhost:1700 for ChirpStack Bridge
cat > /opt/ttn-gateway/packet_forwarder/lora_pkt_fwd/local_conf.json << 'LOCAL_CONF_EOF'
{
    "gateway_conf": {
        "server_address": "127.0.0.1",
        "serv_port_up": 1700,
        "serv_port_down": 1700
    }
}
LOCAL_CONF_EOF

echo "Installing ChirpStack Gateway Bridge..."

# Install ChirpStack Gateway Bridge
cd /opt
wget https://artifacts.chirpstack.io/downloads/chirpstack-gateway-bridge/chirpstack-gateway-bridge_4.0.7_linux_arm64.tar.gz
tar xf chirpstack-gateway-bridge_4.0.7_linux_arm64.tar.gz
cp chirpstack-gateway-bridge /usr/local/bin/
chmod +x /usr/local/bin/chirpstack-gateway-bridge
rm chirpstack-gateway-bridge_4.0.7_linux_arm64.tar.gz

# Create configuration directory
mkdir -p /etc/chirpstack-gateway-bridge

# Create ChirpStack Gateway Bridge configuration
cat > /etc/chirpstack-gateway-bridge/chirpstack-gateway-bridge.toml << 'TOML_EOF'
[integration.mqtt]
event_topic_template="us915_0/gateway/{{ .GatewayID }}/event/{{ .EventType }}"
state_topic_template="us915_0/gateway/{{ .GatewayID }}/state/{{ .StateType }}"
command_topic_template="us915_0/gateway/{{ .GatewayID }}/command/#"

[integration.mqtt.auth.generic]
servers=["ssl://mqtt.parkezesolutions.com:8883"]
TOML_EOF

# Create credentials file in home directory for easy access
cat > /home/parkeze/.gateway-credentials.env << 'MQTT_ENV_EOF'
# MQTT Credentials (edit these values)
MQTT_GATEWAY_ID=your-gateway-id
MQTT_PASSWORD=your-password

# ChirpStack API Configuration for auto-provisioning
CS_API_URL=https://api.parkezesolutions.com/cs
CS_TENANT_ID=${CS_TENANT_ID}
CS_API_TOKEN=${CS_TOKEN}
MQTT_ENV_EOF

chmod 600 /home/parkeze/.gateway-credentials.env
chown parkeze:parkeze /home/parkeze/.gateway-credentials.env

# Create symlink for backward compatibility
mkdir -p /etc/chirpstack-gateway-bridge
ln -sf /home/parkeze/.gateway-credentials.env /etc/chirpstack-gateway-bridge/mqtt-credentials.env

# Create auto-provisioning script
cat > /usr/local/bin/chirpstack-provision-gateway << 'PROVISION_SCRIPT_EOF'
#!/bin/bash

# ChirpStack Gateway Auto-Provisioning Script
# This script registers the gateway with ChirpStack using the API

set -e

# Load configuration
if [ -f /home/parkeze/.gateway-credentials.env ]; then
    source /home/parkeze/.gateway-credentials.env
fi

# Get Gateway EUI from MAC address (same method as RAK)
GATEWAY_EUI_NIC="eth0"
if [[ \$(grep "\$GATEWAY_EUI_NIC" /proc/net/dev) == "" ]]; then
    GATEWAY_EUI_NIC="wlan0"
fi

if [[ \$(grep "\$GATEWAY_EUI_NIC" /proc/net/dev) == "" ]]; then
    echo "ERROR: No network interface found. Cannot determine gateway ID."
    exit 1
fi

GATEWAY_EUI=\$(ip link show \$GATEWAY_EUI_NIC | awk '/ether/ {print \$2}' | awk -F: '{print toupper(\$1\$2\$3"FFFE"\$4\$5\$6)}')

if [ -z "\$GATEWAY_EUI" ]; then
    echo "ERROR: Could not determine Gateway EUI"
    exit 1
fi

echo "Gateway EUI: \$GATEWAY_EUI"

# Update credentials file with actual Gateway ID
sed -i "s/MQTT_GATEWAY_ID=.*/MQTT_GATEWAY_ID=\$GATEWAY_EUI/" /home/parkeze/.gateway-credentials.env

# Check if API configuration is set (env vars or actual values)
if [ "\$CS_API_URL" = "https://api.parkezesolutions.com/cs" ] && [ -z "\${CS_TENANT_ID##*\$*}" ]; then
    echo "ChirpStack API credentials not yet configured (env vars still contain placeholders)."
    echo "Waiting for environment variables to be set in /home/parkeze/.gateway-credentials.env"
    echo "Will retry in 5 minutes..."
    exit 1  # Trigger restart
fi

if [ -z "\$CS_API_URL" ] || [ -z "\$CS_TENANT_ID" ] || [ -z "\$CS_API_TOKEN" ]; then
    echo "ChirpStack API credentials incomplete."
    echo "Please configure in /home/parkeze/.gateway-credentials.env"
    echo "Will retry in 5 minutes..."
    exit 1  # Trigger restart
fi

# Register gateway with ChirpStack
echo "Registering gateway with ChirpStack..."

GATEWAY_NAME="parkeze-\${GATEWAY_EUI: -6}"
GATEWAY_DESCRIPTION="Parkeze LoRaWAN Gateway - Auto-provisioned"

# Create gateway registration JSON
cat > /tmp/gateway.json << GATEWAY_JSON_EOF
{
  "gateway": {
    "gatewayId": "\$GATEWAY_EUI",
    "name": "\$GATEWAY_NAME",
    "description": "\$GATEWAY_DESCRIPTION",
    "location": {
      "latitude": 0,
      "longitude": 0,
      "altitude": 0
    },
    "tenantId": "\$CS_TENANT_ID",
    "statsInterval": 30
  }
}
GATEWAY_JSON_EOF

# Register gateway via API
RESPONSE=\$(curl -s -w "\n%{http_code}" -X POST \\
    "\$CS_API_URL/api/gateways" \\
    -H "Authorization: Bearer \$CS_API_TOKEN" \\
    -H "Content-Type: application/json" \\
    -d @/tmp/gateway.json)

HTTP_CODE=\$(echo "\$RESPONSE" | tail -n1)
BODY=\$(echo "\$RESPONSE" | sed '\$d')

if [ "\$HTTP_CODE" = "200" ] || [ "\$HTTP_CODE" = "201" ]; then
    echo "Gateway registered successfully!"
    rm -f /tmp/gateway.json
    
    # Create marker file to prevent re-provisioning
    touch /var/lib/chirpstack-provisioned
elif [ "\$HTTP_CODE" = "409" ]; then
    echo "Gateway already registered."
    touch /var/lib/chirpstack-provisioned
else
    echo "ERROR: Failed to register gateway. HTTP \$HTTP_CODE"
    echo "\$BODY"
    exit 1
fi
PROVISION_SCRIPT_EOF

chmod +x /usr/local/bin/chirpstack-provision-gateway

# Create one-shot systemd service for auto-provisioning
cat > /etc/systemd/system/chirpstack-provision.service << 'PROVISION_SERVICE_EOF'
[Unit]
Description=ChirpStack Gateway Auto-Provisioning
After=network-online.target
Wants=network-online.target
ConditionPathExists=!/var/lib/chirpstack-provisioned

[Service]
Type=oneshot
ExecStart=/usr/local/bin/chirpstack-provision-gateway
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal
# Retry every 5 minutes if credentials not configured
Restart=on-failure
RestartSec=300

[Install]
WantedBy=multi-user.target
PROVISION_SERVICE_EOF

systemctl enable chirpstack-provision.service

# Create systemd service for ChirpStack Gateway Bridge
cat > /etc/systemd/system/chirpstack-gateway-bridge.service << 'BRIDGE_SERVICE_EOF'
[Unit]
Description=ChirpStack Gateway Bridge
After=network-online.target ttn-gateway.service
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=/etc/chirpstack-gateway-bridge/mqtt-credentials.env
ExecStart=/usr/local/bin/chirpstack-gateway-bridge -c /etc/chirpstack-gateway-bridge/chirpstack-gateway-bridge.toml
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
User=root

[Install]
WantedBy=multi-user.target
BRIDGE_SERVICE_EOF

# Enable ChirpStack Gateway Bridge service
systemctl enable chirpstack-gateway-bridge.service

# Set proper ownership
chown -R root:root /etc/chirpstack-gateway-bridge

echo "Restoring hostname to parkeze..."
# RAK installer changes hostname to rak-gateway, restore to parkeze
echo "parkeze" > /etc/hostname
sed -i 's/rak-gateway/parkeze/g' /etc/hosts

# Remove RAK MOTD (we have our own custom MOTD)
rm -f /etc/motd

# Update /etc/issue for serial console login banner
cat > /etc/issue << 'ISSUE_EOF'
Debian GNU/Linux 13 parkeze ttyS0

My IP address is \4{eth0} \4{wlan0}

ISSUE_EOF

EOF
