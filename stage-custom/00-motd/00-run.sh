#!/bin/bash -e

# Install pyfiglet
install -m 755 files/tmp/generate-motd "${ROOTFS_DIR}/usr/local/bin/"

on_chroot << EOF
# Install pyfiglet and python-dotenv
apt-get update
apt-get install -y python3-pyfiglet python3-dotenv

# Set up dynamic MOTD - clear static motd and use update-motd.d
rm -f /etc/motd
mkdir -p /etc/update-motd.d

# Create update-motd script that runs our Python script
cat > /etc/update-motd.d/00-parkeze << 'MOTD_EOF'
#!/bin/bash
# Clear screen before showing MOTD
clear
/usr/local/bin/generate-motd
MOTD_EOF

chmod +x /etc/update-motd.d/00-parkeze

# Blank out standard MOTD files to prevent them from showing
# Replace 10-uname with an empty script to prevent exec format errors
cat > /etc/update-motd.d/10-uname << 'UNAME_EOF'
#!/bin/sh
# Empty script to disable uname output
exit 0
UNAME_EOF
chmod +x /etc/update-motd.d/10-uname

# Blank other common MOTD files
for motd_file in /etc/update-motd.d/00-header /etc/update-motd.d/10-help-text /etc/update-motd.d/50-motd-news /etc/update-motd.d/80-esm /etc/update-motd.d/90-updates-available /etc/update-motd.d/95-hwe-eol; do
    if [ -f "\$motd_file" ]; then
        echo > "\$motd_file"
    fi
done

# Also blank the main motd file
echo > /etc/motd
EOF
