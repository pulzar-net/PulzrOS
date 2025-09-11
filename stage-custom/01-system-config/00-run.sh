#!/bin/bash -e

# Set timezone to US New York
on_chroot << EOF
# Set timezone
ln -sf /usr/share/zoneinfo/America/New_York /etc/localtime
echo "America/New_York" > /etc/timezone

# Set keyboard layout to US
cat > /etc/default/keyboard << 'KEYBOARD_EOF'
XKBMODEL="pc105"
XKBLAYOUT="us"
XKBVARIANT=""
XKBOPTIONS=""
BACKSPACE="guess"
KEYBOARD_EOF

# Set WiFi country to US to enable WiFi and remove rfkill block
raspi-config nonint do_wifi_country US

# Set locale to US
cat > /etc/locale.gen << 'LOCALE_EOF'
en_US.UTF-8 UTF-8
LOCALE_EOF

echo 'LANG=en_US.UTF-8' > /etc/locale.conf

# Generate locales
locale-gen

# Update locale
update-locale LANG=en_US.UTF-8

# Disable first boot wizard (piwiz) - the main user setup dialog
systemctl disable piwiz 2>/dev/null || true

# Remove piwiz package entirely to prevent any first-boot dialogs
apt-get remove --purge -y piwiz 2>/dev/null || true

# Generate password hash dynamically for 'parkeze' user
PASSWD_HASH=\$(echo "parkeze" | openssl passwd -6 -stdin)

# Create userconf.txt file in boot partition (current method for newer Raspberry Pi OS)
echo "parkeze:\$PASSWD_HASH" > /boot/firmware/userconf.txt

# Also create the legacy userconf file for compatibility
echo "parkeze:\$PASSWD_HASH" > /boot/userconf

# Disable the first-boot configuration service
systemctl disable rpi-oobe 2>/dev/null || true
systemctl mask rpi-oobe 2>/dev/null || true

# Mark setup as already completed to skip first-boot configuration
mkdir -p /etc/systemd/system/multi-user.target.wants/
touch /etc/systemd/system/multi-user.target.wants/.pigen_complete
touch /home/parkeze/.piwiz_done
chown parkeze:parkeze /home/parkeze/.piwiz_done 2>/dev/null || true
EOF
