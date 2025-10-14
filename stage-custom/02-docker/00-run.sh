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

# Create Docker configuration directory
mkdir -p /home/parkeze/.docker
chown parkeze:parkeze /home/parkeze/.docker

# Create cellular-optimized Docker daemon configuration
cat > /etc/docker/daemon.json << 'DOCKER_CONFIG_EOF'
{
  "log-driver": "local",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "storage-driver": "overlay2",
  "live-restore": true,
  "max-concurrent-downloads": 2,
  "max-concurrent-uploads": 2,
  "registry-mirrors": [],
  "insecure-registries": [],
  "features": {
    "buildkit": true
  },
  "experimental": false,
  "metrics-addr": "127.0.0.1:9323",
  "no-new-privileges": true
}
DOCKER_CONFIG_EOF

# Create cellular-optimized Docker client configuration for user
cat > /home/parkeze/.docker/config.json << 'DOCKER_CLIENT_CONFIG_EOF'
{
  "auths": {},
  "HttpHeaders": {
    "User-Agent": "Docker-Client/20.10.0 (linux)"
  },
  "psFormat": "table {{.ID}}\\t{{.Image}}\\t{{.Command}}\\t{{.RunningFor}}\\t{{.Status}}\\t{{.Names}}",
  "imagesFormat": "table {{.Repository}}\\t{{.Tag}}\\t{{.ID}}\\t{{.CreatedSince}}\\t{{.Size}}",
  "pluginsFormat": "table {{.Name}}\\t{{.Version}}\\t{{.Enabled}}",
  "statsFormat": "table {{.Container}}\\t{{.CPUPerc}}\\t{{.MemUsage}}\\t{{.NetIO}}\\t{{.BlockIO}}",
  "experimental": "disabled"
}
DOCKER_CLIENT_CONFIG_EOF

chown parkeze:parkeze /home/parkeze/.docker/config.json

# Enable Docker service to start on boot
systemctl enable docker.service
systemctl enable containerd.service

# Set proper ownership for user files
chown -R parkeze:parkeze /home/parkeze/.docker

echo "Docker installation completed!"

EOF
