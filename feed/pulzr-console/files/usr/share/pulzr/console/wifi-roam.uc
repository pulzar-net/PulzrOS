// One look at the WiFi uplink, for pulzr-wifi-roam. See roam() in
// lib/access.uc for what it decides and why it is slow to decide it.
let access = loadfile('/usr/share/pulzr/console/lib/access.uc', { raw_mode: true })();
let result = access.roam();
if (result.action == 'switched')
    system(sprintf("logger -t pulzr-wifi-roam 'switched from %s to %s: %s'",
                   replace(result.from, /'/g, ''), replace(result.to, /'/g, ''),
                   replace(sprintf('%s %s %s', result.why?.state ?? '', result.why?.step ?? '',
                                   result.why?.detail ?? ''), /[^A-Za-z0-9 ._:,-]/g, '')));
print(sprintf('%J\n', result));
