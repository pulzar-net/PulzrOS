#!/bin/bash -e

# Install pyfiglet
install -m 755 files/tmp/generate-motd "${ROOTFS_DIR}/usr/local/bin/"

on_chroot << EOF
# Install pyfiglet
apt-get update
apt-get install -y python3-pyfiglet

# Set up dynamic MOTD - clear static motd and use update-motd.d
rm -f /etc/motd
mkdir -p /etc/update-motd.d

# Create update-motd script that runs our Python script
cat > /etc/update-motd.d/00-parkeze << 'MOTD_EOF'
#!/bin/bash
/usr/local/bin/generate-motd
MOTD_EOF

chmod +x /etc/update-motd.d/00-parkeze
EOF
