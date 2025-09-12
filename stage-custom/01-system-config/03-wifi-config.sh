#!/bin/bash -e

# WiFi configuration

on_chroot << EOF
# Set WiFi country to US to enable WiFi and remove rfkill block
raspi-config nonint do_wifi_country US
EOF