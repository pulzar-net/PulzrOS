#!/bin/bash -e

# Serial console configuration for headless access

on_chroot << EOF
# Enable serial console login (for headless access via GPIO pins)
# This enables getty on ttyAMA0 (GPIO serial port)
systemctl enable serial-getty@ttyAMA0.service

# Configure serial console settings
# Set up proper baud rate and terminal settings
echo "enable_uart=1" >> /boot/firmware/config.txt

# Ensure serial console is available in /etc/securetty for root login
echo "ttyAMA0" >> /etc/securetty

# Set TERM environment variable for serial console
echo 'export TERM=xterm-256color' >> /etc/profile.d/serial-term.sh
chmod +x /etc/profile.d/serial-term.sh

# Configure serial console in /etc/systemd/system/serial-getty@ttyAMA0.service.d/
mkdir -p /etc/systemd/system/serial-getty@ttyAMA0.service.d/
cat > /etc/systemd/system/serial-getty@ttyAMA0.service.d/override.conf << 'SERIAL_EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty -o '-p -f -- \\u' --keep-baud 115200,57600,38400,9600 %I $TERM
Environment=TERM=xterm-256color
SERIAL_EOF
EOF