# The billed uplinks, for every script that has to keep traffic off them.
#
#   . /usr/share/pulzr/cellular.sh
#
# Two netifd interfaces carry cellular data:
#
#   wwan     the modem ModemManager drives, over QMI, MBIM, or AT and PPP
#   usbwan   a modem that presents itself as a USB Ethernet adapter: a HiLink
#            dongle or a tethered phone (pulzr-usb-cellular)
#
# usbwan is a DHCP client on an Ethernet device, which is exactly what the
# wired uplink is, and nothing about the device says otherwise. Every check
# that named wwan alone would have counted it free: the tunnel's keepalives
# and every LoRa uplink on somebody's phone bill. So nothing names wwan any
# more; it asks here.
#
# wwan first: where both are up, it is the SIM Pulzr provisioned.

. /lib/functions/network.sh

PULZR_CELL_IFACES="${PULZR_WAN_CELL_IFACE:-wwan} usbwan"

# "<gateway> <device>" of the first billed interface with a default route.
# The cache is flushed because pulzr-io calls this in a loop, and
# network.sh keeps the first answer for the life of the shell.
cellular_gateway() {
    local iface gw dev
    network_flush_cache
    for iface in ${PULZR_CELL_IFACES}; do
        network_get_gateway gw "${iface}" || continue
        network_get_device dev "${iface}" || continue
        [ -n "${gw}" ] && [ -n "${dev}" ] || continue
        echo "${gw} ${dev}"
        return 0
    done
    return 1
}

# The device of the first billed interface that is up, gateway or not.
cellular_device() {
    local iface dev
    network_flush_cache
    for iface in ${PULZR_CELL_IFACES}; do
        network_is_up "${iface}" || continue
        network_get_device dev "${iface}" || continue
        [ -n "${dev}" ] && { echo "${dev}"; return 0; }
    done
    return 1
}
