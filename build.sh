#!/bin/bash
set -e

echo "Building ParkezeOS..."

# Check Docker
docker info >/dev/null 2>&1 || { echo "Docker not running"; exit 1; }

# Only clean up the working container, keep build cache
docker rm -v pigen_work 2>/dev/null || true

# Clone pi-gen only if it doesn't exist
if [ ! -d "pi-gen" ]; then
    echo "Cloning pi-gen for first time..."
    git clone https://github.com/RPi-Distro/pi-gen.git
    cd pi-gen
    echo "Using ARM64 branch for 64-bit Pi OS..."
    git checkout arm64
    cd ..
else
    echo "Using existing pi-gen directory..."
    # Update pi-gen to latest (optional - comment out if you want full stability)
    # cd pi-gen && git pull origin arm64 && cd ..
fi

# Copy our custom stage (always refresh to get latest changes)
echo "Updating custom stage..."
rm -rf pi-gen/stage-custom
cp -r stage-custom pi-gen/

# Create config with MOTD customization
cat > pi-gen/config << EOFCONFIG
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
EOFCONFIG

echo "Configuration:"
cat pi-gen/config

# Build the image
cd pi-gen
echo "Starting build..."
./build-docker.sh

echo "Build completed! Check pi-gen/deploy/ for your image."
