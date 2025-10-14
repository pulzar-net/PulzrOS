#!/bin/bash -e

# Configure cellular hardware support for Quectel EC25
# This enables plug-and-play cellular connectivity

on_chroot << EOF

echo "Installing cellular modem support packages..."

# Install cellular modem management packages
apt-get update
apt-get install -y \
    modemmanager \
    network-manager \
    usb-modeswitch \
    usb-modeswitch-data \
    ppp \
    wvdial \
    minicom

# Install Quectel-specific packages if available
apt-get install -y qmi-utils libqmi-utils 2>/dev/null || true

echo "Configuring ModemManager for Quectel EC25..."

# Re-enable ModemManager (was disabled in cellular optimization)
systemctl unmask ModemManager.service 2>/dev/null || true
systemctl enable ModemManager.service

# Configure ModemManager for better Quectel support
cat > /etc/ModemManager/ModemManager.conf << 'MM_CONF_EOF'
[Service]
# Filter for known cellular devices to avoid conflicts
filter-policy=strict

[Logging]
# Reduce logging to save bandwidth
level=WARN
MM_CONF_EOF

echo "Setting up USB mode switching for Quectel EC25..."

# Create udev rules for Quectel EC25 modem
cat > /etc/udev/rules.d/99-quectel-ec25.rules << 'UDEV_EOF'
# Quectel EC25 LTE modem
ATTRS{idVendor}=="2c7c", ATTRS{idProduct}=="0125", RUN+="/sbin/usb_modeswitch -X -v 2c7c -p 0125"
ATTRS{idVendor}=="2c7c", ATTRS{idProduct}=="0125", MODE="0666"

# Additional Quectel device IDs
ATTRS{idVendor}=="2c7c", ATTRS{idProduct}=="0121", MODE="0666"
ATTRS{idVendor}=="2c7c", ATTRS{idProduct}=="0191", MODE="0666"
ATTRS{idVendor}=="2c7c", ATTRS{idProduct}=="0195", MODE="0666"
UDEV_EOF

echo "Configuring NetworkManager for automatic cellular connection..."

# Create NetworkManager cellular connection profile
cat > /etc/NetworkManager/system-connections/cellular-auto.nmconnection << 'NM_CELLULAR_EOF'
[connection]
id=Cellular Auto
type=gsm
autoconnect=true
autoconnect-priority=10

[gsm]
# Common APNs - NetworkManager will try to auto-detect
# Leaving APN empty for auto-detection
apn=
username=
password=
# Enable auto APN detection
auto-config=true

[ipv4]
method=auto
dns-priority=100

[ipv6]
method=ignore
NM_CELLULAR_EOF

# Set proper permissions for NetworkManager connection
chmod 600 /etc/NetworkManager/system-connections/cellular-auto.nmconnection

echo "Setting up common APN database for auto-detection..."

# Create APN database for common carriers
cat > /etc/NetworkManager/conf.d/cellular-apn-defaults.conf << 'APN_CONF_EOF'
[gsm-apn-defaults]
# Common US carrier APNs
310410=fast.t-mobile.com
310260=fast.t-mobile.com
311480=fast.t-mobile.com
310120=phone
312530=phone
311870=vzwinternet
311480=broadband

# Common international APNs
23420=internet.t-mobile.nl
26207=internet.t-mobile.de
20404=internet.t-mobile.nl
23003=tre.it
APN_CONF_EOF

echo "Configuring automatic cellular monitoring..."

# Create a service to automatically start cellular monitoring when modem connects
cat > /etc/systemd/system/cellular-autostart.service << 'AUTOSTART_EOF'
[Unit]
Description=Auto-start cellular connection monitoring
After=ModemManager.service NetworkManager.service
Wants=ModemManager.service NetworkManager.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'sleep 30 && nmcli connection up cellular-auto 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
AUTOSTART_EOF

systemctl enable cellular-autostart.service

echo "Configuring boot-time cellular activation..."

# Add cellular startup to rc.local equivalent
cat > /etc/systemd/system/cellular-boot.service << 'CELLULAR_BOOT_EOF'
[Unit]
Description=Initialize cellular connection on boot
After=multi-user.target ModemManager.service NetworkManager.service
Wants=ModemManager.service NetworkManager.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'sleep 45 && nmcli connection up cellular-auto'
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
CELLULAR_BOOT_EOF

systemctl enable cellular-boot.service

echo "Cellular hardware support configured!"

EOF