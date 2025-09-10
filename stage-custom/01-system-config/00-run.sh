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

# Set locale to US
cat > /etc/locale.gen << 'LOCALE_EOF'
en_US.UTF-8 UTF-8
LOCALE_EOF

echo 'LANG=en_US.UTF-8' > /etc/locale.conf

# Generate locales
locale-gen

# Update locale
update-locale LANG=en_US.UTF-8
EOF
