// What the terminal UI reads and changes: the web console's own modules.
//
// Reads call lib/ directly, as api/index.uc's GET routes do. Changes go
// through lib/actions.uc and nowhere else, so an action taken here is
// validated and audited exactly as the same action taken in a browser.

const LIB = '/usr/share/parkeze/console/lib/';
const load = (name) => loadfile(LIB + name + '.uc', { raw_mode: true })();

return {
    auth: load('auth'),
    system: load('system'),
    network: load('network'),
    lorawan: load('lorawan'),
    claim: load('claim'),
    io: load('io'),
    access: load('access'),
    bluetooth: load('bluetooth'),
    actions: load('actions'),
};
