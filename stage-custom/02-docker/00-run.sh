#!/bin/bash -e

# Install Docker using official install script and set up rootless mode
on_chroot << EOF
# Update package index
apt-get update

# Install prerequisites for Docker
apt-get install -y \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    uidmap \
    dbus-user-session \
    fuse-overlayfs \
    slirp4netns

# Try Docker installation with fallback methods
echo "Attempting Docker installation..."

# Method 1: Official Docker script
if curl -fsSL https://get.docker.com -o get-docker.sh; then
    echo "Running official Docker installation script..."
    if DEBIAN_FRONTEND=noninteractive sh get-docker.sh; then
        echo "Docker installed successfully via official script"
        rm get-docker.sh
    else
        echo "Official script failed, trying alternative method..."
        rm -f get-docker.sh
        
        # Method 2: Manual repository setup
        echo "Setting up Docker repository manually..."
        mkdir -p /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        echo "deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \$(. /etc/os-release && echo \"\$VERSION_CODENAME\") stable" > /etc/apt/sources.list.d/docker.list
        
        apt-get update
        apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin
    fi
else
    echo "Failed to download Docker script, trying repository method..."
    # Method 2: Manual repository setup
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    echo "deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \$(. /etc/os-release && echo \"\$VERSION_CODENAME\") stable" > /etc/apt/sources.list.d/docker.list
    
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin
fi

echo "Configuring Docker services..."
# Enable services (manually create symlinks since systemctl doesn't work in chroot)
mkdir -p /etc/systemd/system/multi-user.target.wants
mkdir -p /etc/systemd/system/sockets.target.wants

# Enable docker.service
ln -sf /lib/systemd/system/docker.service /etc/systemd/system/multi-user.target.wants/docker.service 2>/dev/null || true
# Enable docker.socket  
ln -sf /lib/systemd/system/docker.socket /etc/systemd/system/sockets.target.wants/docker.socket 2>/dev/null || true
# Enable containerd.service
ln -sf /lib/systemd/system/containerd.service /etc/systemd/system/multi-user.target.wants/containerd.service 2>/dev/null || true

# Add the default user to docker group (for regular Docker usage)
usermod -aG docker parkeze

# Set up rootless Docker for the parkeze user (to be installed on first boot)
# Create systemd user service directory
mkdir -p /home/parkeze/.config/systemd/user

# Create a script to install rootless Docker on first boot
cat > /usr/local/bin/setup-rootless-docker << 'ROOTLESS_SETUP_EOF'
#!/bin/bash
# This script sets up rootless Docker on first boot when kernel modules are available

if [ ! -f /home/parkeze/.rootless-docker-installed ]; then
    echo "Setting up rootless Docker for parkeze user..."
    
    # Enable lingering for parkeze user (allows services to start on boot)
    loginctl enable-linger parkeze || echo "Warning: Could not enable linger"
    
    # Install rootless Docker as the parkeze user
    runuser -l parkeze -c 'curl -fsSL https://get.docker.com/rootless | sh'
    
    # Enable rootless Docker service for parkeze user
    runuser -l parkeze -c 'systemctl --user enable docker'
    
    # Mark as installed
    touch /home/parkeze/.rootless-docker-installed
    chown parkeze:parkeze /home/parkeze/.rootless-docker-installed
    
    echo "Rootless Docker setup completed!"
else
    echo "Rootless Docker already installed"
fi
ROOTLESS_SETUP_EOF

chmod +x /usr/local/bin/setup-rootless-docker

# Create a systemd service to run rootless Docker setup on first boot
cat > /etc/systemd/system/setup-rootless-docker.service << 'SERVICE_EOF'
[Unit]
Description=Setup Rootless Docker on First Boot
After=multi-user.target
ConditionPathExists=!/home/parkeze/.rootless-docker-installed

[Service]
Type=oneshot
ExecStart=/usr/local/bin/setup-rootless-docker
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SERVICE_EOF

# Enable the service to run on boot (manually create symlink since systemctl doesn't work in chroot)
mkdir -p /etc/systemd/system/multi-user.target.wants
ln -sf /etc/systemd/system/setup-rootless-docker.service /etc/systemd/system/multi-user.target.wants/setup-rootless-docker.service

# Set up environment for rootless Docker
cat >> /home/parkeze/.bashrc << 'DOCKER_ENV_EOF'

# Docker rootless setup
export PATH=/home/parkeze/bin:\$PATH
export DOCKER_HOST=unix:///run/user/1000/docker.sock

DOCKER_ENV_EOF

# Create a script to easily switch between regular and rootless Docker
cat > /usr/local/bin/docker-rootless << 'ROOTLESS_SCRIPT_EOF'
#!/bin/bash
# Switch to rootless Docker mode
export PATH=/home/parkeze/bin:\$PATH
export DOCKER_HOST=unix:///run/user/1000/docker.sock
exec docker "\$@"
ROOTLESS_SCRIPT_EOF

chmod +x /usr/local/bin/docker-rootless

# Create a helper script for Docker management
cat > /usr/local/bin/docker-setup-info << 'INFO_SCRIPT_EOF'
#!/bin/bash
echo "Docker Setup Information:"
echo "========================="
echo "Regular Docker (requires sudo or docker group):"
echo "  docker --version"
echo ""
echo "Rootless Docker (runs as user without sudo):"
if [ -f /home/parkeze/.rootless-docker-installed ]; then
    echo "  docker-rootless --version"
    echo "  DOCKER_HOST=unix:///run/user/1000/docker.sock docker --version"
    echo ""
    echo "To start rootless Docker service:"
    echo "  systemctl --user start docker"
else
    echo "  Rootless Docker will be installed on first boot"
    echo "  Or run: sudo /usr/local/bin/setup-rootless-docker"
fi
echo ""
echo "To enable rootless Docker on boot:"
echo "  systemctl --user enable docker"
echo "  sudo loginctl enable-linger parkeze"
echo ""
echo "Current Docker status:"
if systemctl is-active --quiet docker; then
    echo "  ✓ Regular Docker service is running"
else
    echo "  ✗ Regular Docker service is not running"
fi

if runuser -l parkeze -c 'systemctl --user is-active --quiet docker' 2>/dev/null; then
    echo "  ✓ Rootless Docker service is running"
else
    echo "  ✗ Rootless Docker service is not running"
fi
INFO_SCRIPT_EOF

chmod +x /usr/local/bin/docker-setup-info

# Enable lingering for parkeze user (allows rootless Docker to start on boot)
# Note: This will fail in chroot, but will work once the system boots
loginctl enable-linger parkeze 2>/dev/null || echo "Note: loginctl enable-linger will be set up on first boot"

# Create Docker configuration directory
mkdir -p /home/parkeze/.docker
chown parkeze:parkeze /home/parkeze/.docker

# Set proper ownership for user files
chown -R parkeze:parkeze /home/parkeze/.config
chown -R parkeze:parkeze /home/parkeze/bin 2>/dev/null || true

echo "Docker installation completed with rootless support!"
echo "Run 'docker-setup-info' for usage information."
EOF
