# Sourced by sysupgrade (`include /lib/upgrade`), as the platform's own
# upgrade scripts are.
#
# pulzr-legacy names (01-pulzr-migrate) renamed the WiFi uplink's station and the setup AP from
# ParkezeOS's names (parkeze_sta, parkeze_ap) to pulzr_sta and
# pulzr_setup_ap. An older image, PulzrOS or ParkezeOS, reads only the old
# ones: flashed back to (by hand, or by pulzr-firmware's rollback after an
# upgrade that failed its health check), it would find the WiFi it is on and
# not know it is the uplink. On a gateway whose only way home is that WiFi,
# that is a truck.
#
# So every config backup carries a uci-defaults script, the way sysupgrade
# carries its own 10_disable_services, that puts the old names back. It acts
# only on an image without this file: one that has it knows the new names,
# and its own 01-pulzr-migrate renames forward after it. PULZR_ROOT is
# scripts/test-legacy.sh's fake root. Written into
# /etc/uci-defaults on the running system as well, where it is a no-op if
# the upgrade never happens.
#
# Also its own marker: an image that ships this file knows the new names.

pulzr_names_back() {
	local script="${PULZR_ROOT:-}/etc/uci-defaults/00-pulzr-names-back"
	mkdir -p "${PULZR_ROOT:-}/etc/uci-defaults"
	cat > "${script}" <<'SCRIPT'
#!/bin/sh
# Written by /lib/upgrade/pulzr-names.sh into the sysupgrade backup.
[ -n "${IPKG_INSTROOT}" ] && exit 0
[ -f "${PULZR_ROOT:-}/lib/upgrade/pulzr-names.sh" ] && exit 0
renamed=""
for pair in pulzr_sta:parkeze_sta pulzr_setup_ap:parkeze_ap; do
    new="${pair%%:*}"; old="${pair#*:}"
    [ -n "$(uci -q get "wireless.${new}")" ] && [ -z "$(uci -q get "wireless.${old}")" ] || continue
    uci -q rename "wireless.${new}=${old}" && renamed=1
done
[ -z "${renamed}" ] || uci -q commit wireless
exit 0
SCRIPT
	echo "${script}" >> "$1"
}

append sysupgrade_init_conffiles pulzr_names_back
