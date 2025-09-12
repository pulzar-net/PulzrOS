#!/bin/bash -e

# User and authentication configuration

on_chroot << EOF
# Generate password hash dynamically for 'parkeze' user
PASSWD_HASH=\$(echo "parkeze" | openssl passwd -6 -stdin)

# Create userconf.txt file in boot partition (current method for newer Raspberry Pi OS)
echo "parkeze:\$PASSWD_HASH" > /boot/firmware/userconf.txt

# Also create the legacy userconf file for compatibility
echo "parkeze:\$PASSWD_HASH" > /boot/userconf

# Disable first boot wizard (piwiz) - the main user setup dialog
systemctl disable piwiz 2>/dev/null || true

# Remove piwiz package entirely to prevent any first-boot dialogs
apt-get remove --purge -y piwiz 2>/dev/null || true

# Disable the first-boot configuration service
systemctl disable rpi-oobe 2>/dev/null || true
systemctl mask rpi-oobe 2>/dev/null || true

# Mark setup as already completed to skip first-boot configuration
mkdir -p /etc/systemd/system/multi-user.target.wants/
touch /etc/systemd/system/multi-user.target.wants/.pigen_complete
touch /home/parkeze/.piwiz_done
chown parkeze:parkeze /home/parkeze/.piwiz_done 2>/dev/null || true
EOF