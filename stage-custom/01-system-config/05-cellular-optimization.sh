#!/bin/bash -e

# Network optimization for cellular backhaul
# Minimize outbound communications and data usage

on_chroot << EOF
# Disable automatic package updates and upgrades
systemctl disable apt-daily.timer
systemctl disable apt-daily-upgrade.timer
systemctl disable apt-daily.service
systemctl disable apt-daily-upgrade.service

# Mask the services to prevent them from being started
systemctl mask apt-daily.timer
systemctl mask apt-daily-upgrade.timer
systemctl mask apt-daily.service
systemctl mask apt-daily-upgrade.service

# Configure APT to not automatically download package lists
mkdir -p /etc/apt/apt.conf.d
cat > /etc/apt/apt.conf.d/20auto-upgrades << 'APT_EOF'
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Download-Upgradeable-Packages "0";
APT::Periodic::AutocleanInterval "0";
APT::Periodic::Unattended-Upgrade "0";
APT_EOF

# Disable snapd if present (uses significant bandwidth)
systemctl disable snapd.service 2>/dev/null || true
systemctl disable snapd.socket 2>/dev/null || true
systemctl mask snapd.service 2>/dev/null || true
systemctl mask snapd.socket 2>/dev/null || true

# Configure systemd to minimize network discovery
mkdir -p /etc/systemd/network
cat > /etc/systemd/network/99-cellular-optimized.network << 'NETWORK_EOF'
[Match]
Type=wwan cellular

[Network]
# Disable IPv6 to reduce overhead
IPv6AcceptRA=no
DHCP=ipv4

[DHCPv4]
# Minimize DHCP traffic
SendHostname=no
SendRelease=no
SendDecline=no
NETWORK_EOF

# Disable unnecessary network services
systemctl disable avahi-daemon.service 2>/dev/null || true
systemctl disable wpa_supplicant.service 2>/dev/null || true

# Configure NTP to use fewer servers and longer intervals
cat > /etc/systemd/timesyncd.conf << 'NTP_EOF'
[Time]
# Use fewer NTP servers to reduce network calls
NTP=time.nist.gov
# Increase polling interval to reduce frequency
PollIntervalMinSec=1024
PollIntervalMaxSec=2048
# Don't fallback to other servers quickly
ConnectionRetrySec=60
NTP_EOF

# Note: ModemManager is needed for cellular functionality
# It will be configured in the cellular hardware setup script

# Configure rsyslog to minimize network logging
mkdir -p /etc/rsyslog.d
cat > /etc/rsyslog.d/99-cellular-optimized.conf << 'RSYSLOG_EOF'
# Disable remote logging to save bandwidth
# Only log locally
*.* /var/log/syslog
RSYSLOG_EOF

# Disable automatic firmware updates
mkdir -p /etc/default
echo 'FIRMWARE_RELEASE_STATUS="never"' >> /etc/default/rpi-eeprom-update

# Configure logrotate for smaller logs (less disk usage)
mkdir -p /etc/logrotate.d
cat > /etc/logrotate.d/cellular-optimized << 'LOGROTATE_EOF'
/var/log/*.log {
    daily
    missingok
    rotate 3
    compress
    delaycompress
    sharedscripts
    copytruncate
    maxsize 10M
}
LOGROTATE_EOF

# Disable telemetry and analytics
mkdir -p /etc/systemd/system
cat > /etc/systemd/system/disable-telemetry.service << 'TELEMETRY_EOF'
[Unit]
Description=Disable various telemetry services
After=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'systemctl mask whoopsie.service 2>/dev/null || true'
ExecStart=/bin/bash -c 'systemctl mask ubuntu-report.service 2>/dev/null || true'
ExecStart=/bin/bash -c 'systemctl mask popularity-contest.service 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
TELEMETRY_EOF

systemctl enable disable-telemetry.service

# Configure NetworkManager for cellular optimization (but keep cellular support)
mkdir -p /etc/NetworkManager/conf.d
cat > /etc/NetworkManager/conf.d/99-cellular-optimized.conf << 'NM_EOF'
[main]
# Reduce automatic network scanning
autoconnect-retries-default=1

[connection]
# Reduce connection timeout
ipv4.dhcp-timeout=30
ipv6.addr-gen-mode=eui64

[device]
# Disable WiFi scanning when not needed (but allow cellular)
wifi.scan-rand-mac-address=no
wifi.powersave=3

[gsm]
# Optimize cellular connections for data usage
auto-config=true
NM_EOF

echo "Network optimization for cellular backhaul completed"
EOF