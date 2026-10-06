// One look at the WiFi uplink, for parkeze-wifi-roam. See roam() in
// lib/access.uc for what it decides and why it is slow to decide it.
let access = loadfile('/usr/share/parkeze/console/lib/access.uc', { raw_mode: true })();
let result = access.roam();
if (result.action == 'switched')
    system(sprintf("logger -t parkeze-wifi-roam 'switched from %s to %s'",
                   replace(result.from, /'/g, ''), replace(result.to, /'/g, '')));
print(sprintf('%J\n', result));
