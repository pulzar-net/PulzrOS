#!/bin/bash -e

# Install and configure LoRaWAN gateway services for RAK5146

install -m 644 files/gateway-credentials.env "${ROOTFS_DIR}/home/parkeze/.gateway-credentials.env"
install -m 644 files/local_conf.json "${ROOTFS_DIR}/tmp/local_conf.json"
install -m 644 files/chirpstack-gateway-bridge.toml "${ROOTFS_DIR}/tmp/chirpstack-gateway-bridge.toml"
install -m 755 files/chirpstack-gateway-bridge-wrapper.sh "${ROOTFS_DIR}/tmp/chirpstack-gateway-bridge-wrapper.sh"
install -m 644 files/issue "${ROOTFS_DIR}/tmp/issue"
install -m 755 files/chirpstack-provision-gateway "${ROOTFS_DIR}/tmp/chirpstack-provision-gateway"
install -m 644 files/chirpstack-provision.service "${ROOTFS_DIR}/tmp/chirpstack-provision.service"
install -m 644 files/chirpstack-gateway-bridge.service "${ROOTFS_DIR}/tmp/chirpstack-gateway-bridge.service"

on_chroot << EOF

echo "Installing LoRaWAN gateway packages..."

# Update package index
apt-get update

# Install git and Python dependencies for provisioning
apt-get install -y git python3-dotenv python3-requests

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
cp /tmp/local_conf.json /opt/ttn-gateway/packet_forwarder/lora_pkt_fwd/local_conf.json

# Configure for US915 frequency plan by default
echo "Configuring RAK5146 for US915 (902-928 MHz)..."
cp /opt/rak_common_for_gateway/lora/rak5146/global_conf_usb/global_conf.us_902_928.json /opt/ttn-gateway/packet_forwarder/lora_pkt_fwd/global_conf.json

# Fix the Gateway ID to use actual MAC address instead of default AA555A0000000000
# This script will run on first boot to set the correct Gateway EUI
cat > /usr/local/bin/update-gateway-id.sh << 'SCRIPT'
#!/bin/bash
# Update Gateway ID based on eth0 MAC address

# Get MAC address from eth0
MAC=$(cat /sys/class/net/eth0/address 2>/dev/null || echo "aa:55:5a:00:00:00")

# Convert MAC to EUI64 format (insert FFFE in the middle)
MAC_CLEAN=$(echo $MAC | tr -d ':' | tr '[:lower:]' '[:upper:]')
GATEWAY_EUI="${MAC_CLEAN:0:6}FFFE${MAC_CLEAN:6:6}"

# Update global_conf.json with the correct Gateway ID
sed -i "s/\"gateway_ID\": \"[^\"]*\"/\"gateway_ID\": \"$GATEWAY_EUI\"/" /opt/ttn-gateway/packet_forwarder/lora_pkt_fwd/global_conf.json

echo "Gateway ID set to: $GATEWAY_EUI"
SCRIPT

chmod +x /usr/local/bin/update-gateway-id.sh

# Create a systemd service to run this before ttn-gateway starts
cat > /etc/systemd/system/update-gateway-id.service << 'SERVICE'
[Unit]
Description=Update LoRaWAN Gateway ID from MAC address
Before=ttn-gateway.service
DefaultDependencies=no

[Service]
Type=oneshot
ExecStart=/usr/local/bin/update-gateway-id.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SERVICE

systemctl enable update-gateway-id.service

# Run it now during build (will use build machine's MAC, but will be corrected on first boot)
/usr/local/bin/update-gateway-id.sh

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

# Copy ChirpStack Gateway Bridge configuration template
cp /tmp/chirpstack-gateway-bridge.toml /etc/chirpstack-gateway-bridge/chirpstack-gateway-bridge.toml.template

# Install wrapper script that substitutes credentials at runtime
cp /tmp/chirpstack-gateway-bridge-wrapper.sh /usr/local/bin/chirpstack-gateway-bridge-wrapper.sh
chmod +x /usr/local/bin/chirpstack-gateway-bridge-wrapper.sh

# Set up credentials file in home directory
chmod 600 /home/parkeze/.gateway-credentials.env
chown parkeze:parkeze /home/parkeze/.gateway-credentials.env

# Create symlink for backward compatibility
ln -sf /home/parkeze/.gateway-credentials.env /etc/chirpstack-gateway-bridge/mqtt-credentials.env

# Install auto-provisioning script and services
cp /tmp/chirpstack-provision-gateway /usr/local/bin/chirpstack-provision-gateway
chmod +x /usr/local/bin/chirpstack-provision-gateway

cp /tmp/chirpstack-provision.service /etc/systemd/system/chirpstack-provision.service
systemctl enable chirpstack-provision.service

cp /tmp/chirpstack-gateway-bridge.service /etc/systemd/system/chirpstack-gateway-bridge.service
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
cp /tmp/issue /etc/issue

# Cleanup temp files
rm -f /tmp/local_conf.json /tmp/chirpstack-gateway-bridge.toml /tmp/chirpstack-gateway-bridge-wrapper.sh /tmp/issue
rm -f /tmp/chirpstack-provision-gateway /tmp/chirpstack-provision.service /tmp/chirpstack-gateway-bridge.service

EOF
