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

# Download and run Docker's official installation script
curl -fsSL https://get.docker.com -o get-docker.sh
sh get-docker.sh

# Clean up the installation script
rm get-docker.sh

# Enable and start Docker service
systemctl enable docker
systemctl enable containerd

# Add the default user to docker group (for regular Docker usage)
usermod -aG docker parkeze

# Install Docker Compose (latest version)
curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-\$(uname -s)-\$(uname -m)" -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

# Set up rootless Docker for the parkeze user
# Create systemd user service directory
mkdir -p /home/parkeze/.config/systemd/user

# Install rootless Docker
runuser -l parkeze -c 'curl -fsSL https://get.docker.com/rootless | sh'

# Enable rootless Docker service for parkeze user
runuser -l parkeze -c 'systemctl --user enable docker'

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
echo "  docker-compose --version"
echo ""
echo "Rootless Docker (runs as user without sudo):"
echo "  docker-rootless --version"
echo "  DOCKER_HOST=unix:///run/user/1000/docker.sock docker --version"
echo ""
echo "To start rootless Docker service:"
echo "  systemctl --user start docker"
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
loginctl enable-linger parkeze

# Create Docker configuration directory
mkdir -p /home/parkeze/.docker
chown parkeze:parkeze /home/parkeze/.docker

# Set proper ownership for user files
chown -R parkeze:parkeze /home/parkeze/.config
chown -R parkeze:parkeze /home/parkeze/bin 2>/dev/null || true

echo "Docker installation completed with rootless support!"
echo "Run 'docker-setup-info' for usage information."
EOF
