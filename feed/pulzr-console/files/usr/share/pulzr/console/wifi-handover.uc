// One handover, for lib/radios.uc's joinUplink: a second radio's station
// proven and put ahead of the WiFi uplink carrying the traffic, or removed
// again. Started in the background; see the header of lib/radios.uc.
let radios = loadfile('/usr/share/pulzr/console/lib/radios.uc', { raw_mode: true })();
let iface = ARGV[0];
if (!(iface in ['wwifi', 'wwifi2'])) exit(2);
let h = radios.handover(iface);
if (h?.state)
    system(sprintf("logger -t wifi-handover '%s on %s: %s %s'", iface, replace(h.radio ?? '', /[^A-Za-z0-9_]/g, ''),
                   h.state, replace(h.reason ?? h.failure?.code ?? '', /[^A-Za-z0-9 ._:,-]/g, '')));
