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
cat > /etc/profile.d/serial-term.sh << 'TERM_SCRIPT_EOF'
#!/bin/bash
# Set TERM environment variable

if [ -z "$TERM" ] || [ "$TERM" = "unknown" ]; then
    export TERM=xterm-256color
fi
TERM_SCRIPT_EOF

chmod +x /etc/profile.d/serial-term.sh

# Also set it in the user's shell profiles
echo 'export TERM=xterm-256color' >> /home/parkeze/.bashrc
echo 'export TERM=xterm-256color' >> /home/parkeze/.profile

# Configure serial console in /etc/systemd/system/serial-getty@ttyAMA0.service.d/
mkdir -p /etc/systemd/system/serial-getty@ttyAMA0.service.d/
cat > /etc/systemd/system/serial-getty@ttyAMA0.service.d/override.conf << 'SERIAL_EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty -o '-p -f -- \\u' --keep-baud 115200,57600,38400,9600 %I xterm-256color
Environment=TERM=xterm-256color
Type=idle
Restart=always
RestartSec=0
SERIAL_EOF
EOF