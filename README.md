# ParkezeOS - Cellular-Optimized Raspberry Pi OS

A custom Raspberry Pi OS build optimized for cellular backhaul deployments with Docker support and comprehensive network optimization.

## 🎯 Purpose

ParkezeOS is designed for IoT gateways and edge computing devices that rely on cellular connections for internet access. It minimizes data usage while providing a full Docker-enabled Linux environment.

## 📶 Cellular Optimization Features

### Network Traffic Minimization
- **Automatic updates disabled** - No surprise data usage from package updates
- **Optimized time sync** - Reduced NTP polling frequency
- **Discovery services disabled** - No unnecessary network broadcasts
- **Compressed logging** - Minimal log storage and transmission
- **Telemetry disabled** - No data sent to third parties

### Docker Configuration
- **Limited concurrent operations** - Reduces peak bandwidth usage
- **Optimized registry calls** - Minimizes Docker Hub requests
- **Local logging only** - No remote log shipping
- **Efficient image builds** - BuildKit enabled for smaller transfers

## 🛠️ Built-in Cellular Tools

### `cellular-monitor` Command
Monitor and manage cellular data usage:

```bash
# Show current data usage
cellular-monitor show

# Log usage data (runs automatically every 15 minutes)
cellular-monitor log

# Apply low-bandwidth optimizations
cellular-monitor optimize

# Reset usage tracking
cellular-monitor reset
```

### `network-optimize` Command
Apply runtime network optimizations for cellular connections:

```bash
# Optimize TCP settings and disable unnecessary services
sudo network-optimize
```

### Usage Monitoring
- **Automatic logging** every 15 minutes via systemd timer
- **Threshold alerts** when usage exceeds configured limits
- **Per-interface statistics** for all cellular connections
- **Historical tracking** with log rotation

## 🔧 System Configuration

### Default Settings
- **User**: `parkeze` / **Password**: `parkeze`
- **Timezone**: America/New_York
- **Locale**: en_US.UTF-8
- **WiFi Country**: US
- **SSH**: Enabled
- **Serial Console**: Enabled (115200 baud on GPIO 14/15)

### Disabled Services
- Automatic package updates (apt-daily)
- Avahi daemon (network discovery)
- ModemManager auto-probing
- Snapd (if present)
- Various telemetry services

### Docker Support
- **Docker CE** installed via official script
- **Rootless Docker** available for user `parkeze`
- **Cellular-optimized** daemon configuration
- **BuildKit** enabled for efficient builds

## 📱 Cellular Connection Setup

### Supported Interfaces
The monitoring tools automatically detect cellular interfaces:
- `wwan*` - WWAN modems
- `ppp*` - PPP connections
- `rmnet*` - Qualcomm modems

### Data Usage Tracking
Usage logs are stored in `/var/log/cellular-usage.log` with format:
```
2025-09-11 15:30:00,RX:1048576,TX:2097152,Total:3MB
```

### Optimization Levels
1. **Default** - Basic cellular optimizations applied
2. **Low Bandwidth** - Additional restrictions via `cellular-monitor optimize`
3. **Emergency** - Manual service disabling via `network-optimize`

## 🚀 Getting Started

1. **Flash ParkezeOS** to SD card and boot Raspberry Pi
2. **Connect via SSH** or serial console (user: `parkeze`, pass: `parkeze`)
3. **Check cellular status**: `cellular-monitor show`
4. **Optimize if needed**: `cellular-monitor optimize`
5. **Deploy Docker applications** with confidence in data usage control

## 📊 Typical Data Savings

Compared to standard Raspberry Pi OS:
- **50-80% reduction** in background traffic
- **No automatic updates** consuming unexpected data
- **Minimal time sync** overhead (hourly vs. every few minutes)
- **Controlled Docker operations** preventing bandwidth spikes
- **Local logging only** - no remote telemetry

## 🏗️ Build Information

Built using pi-gen with custom stages:
- **Stage 0-2**: Standard Raspberry Pi OS base
- **stage-custom/00-motd**: Custom boot message with system info
- **stage-custom/01-system-config**: Timezone, locale, user setup, cellular optimization
- **stage-custom/02-docker**: Docker installation with cellular-aware configuration

## 📞 Support

This is a specialized build for cellular IoT deployments. For cellular-specific issues:
1. Check data usage: `cellular-monitor show`
2. Review optimization status: `systemctl status cellular-monitor.timer`
3. Apply emergency optimization: `sudo network-optimize`
4. Check cellular interfaces: `ip link show | grep -E "wwan|ppp|rmnet"`

## 🔒 Security Notes

- **Default credentials** should be changed immediately
- **SSH is enabled** - secure with key-based authentication
- **Serial console enabled** - physical access provides root access
- **Cellular optimizations** may affect some network-dependent services

---

**ParkezeOS** - Optimized for the Edge, Designed for Cellular 📶