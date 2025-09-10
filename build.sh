#!/bin/bash
set -e

echo "Building 64-bit Pi OS with MOTD customization..."

# Check Docker
docker info >/dev/null 2>&1 || { echo "Docker not running"; exit 1; }

# Clean up
docker rm -v pigen_work 2>/dev/null || true
docker system prune -f
rm -rf pi-gen

# Get fresh pi-gen with ARM64 branch for macOS compatibility
git clone https://github.com/RPi-Distro/pi-gen.git
cd pi-gen
echo "Using ARM64 branch for 64-bit Pi OS..."
git checkout arm64
cd ..

# Copy our custom MOTD stage
echo "Adding custom MOTD stage..."
cp -r stage-custom pi-gen/

# Create config with MOTD customization
cat > pi-gen/config << EOF
IMG_NAME='ParkezeOS'
STAGE_LIST="stage0 stage1 stage2 stage-custom"
TARGET_HOSTNAME=parkeze
FIRST_USER_NAME=parkeze
FIRST_USER_PASS=parkeze
ENABLE_SSH=1
TIMEZONE_DEFAULT=America/New_York
KEYBOARD_KEYMAP=us
KEYBOARD_LAYOUT=US
LOCALE_DEFAULT=en_US.UTF-8
EOF

echo "Configuration:"
cat pi-gen/config

# Build the image
cd pi-gen
echo "Starting build..."
./build-docker.sh

echo "Build completed! Check pi-gen/deploy/ for your image."
