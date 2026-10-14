// Panel — console/src/pages/Panel.tsx.
return function(ctx) {
    const ui = ctx.ui, api = ctx.api;
    const st = { io: null, tested: false };

    // The blink codes are parkeze-io's, and do not change at runtime.
    const CODES = [
        [ 'Power', 'Solid', 'The gateway is up.' ],
        [ 'Status', 'Heartbeat', 'Healthy and adopted.' ],
        [ 'Status', 'Blink, 1/second', 'Wants attention: not adopted, or running at reduced channel count.' ],
        [ 'Status', 'Blink, fast', 'Fault: no concentrator responded at all.' ],
        [ 'Cloud', 'Solid', 'Reachable over the wired path (management tunnel).' ],
        [ 'Cloud', 'Blink, slow', 'Reachable over cellular only — working, but every byte is billed.' ],
        [ 'Cloud', 'Off', 'No management path at all.' ],
        [ 'Cellular', 'Solid', 'Modem attached.' ],
        [ 'Cellular', 'Blink', 'Modem attaching.' ],
        [ 'LoRa', 'Flash', 'One flash per uplink heard.' ],
    ];

    return {
        load: function() { st.io = api.io.status(); },
        view: function(width) {
            const io = st.io, out = [];
            if (st.tested)
                push(out, { t: 'notice', tone: 'success', text: 'Walking every mapped LED in turn. Watch the panel — anything that does not light is mapped to a name this board does not have.' });

            push(out, { t: 'section', title: 'LEDs' });
            push(out, { t: 'buttons', items: [ { label: 'Lamp test', run: () => { ctx.act('ioTest'); st.tested = true; } } ] });
            let missing = false;
            for (let l in (io.leds ?? [])) {
                push(out, { t: 'fact', label: l.logical, value: l.present ? l.physical : { badge: 'Not on this board', tone: 'neutral' } });
                if (!l.present) missing = true;
            }
            if (missing && length(io.available ?? [])) {
                push(out, { t: 'blank' });
                push(out, { t: 'fact', label: 'Unmapped', value: join(', ', io.available) });
            }

            push(out, { t: 'section', title: 'Blink codes' });
            // The LED in the label column and its state leading the value: "Status
            // · Blink, 1/second" is wider than any label column a terminal has.
            for (let c in CODES)
                push(out, { t: 'fact', label: c[0], value: c[1] + ': ' + c[2] });

            push(out, { t: 'section', title: 'Reset button' });
            const button = io.button ?? {};
            if (button.reset) {
                push(out, { t: 'fact', label: 'Short press', value: 'Reports whether the gateway is manageable, on the cloud LED. Harmless.' });
                push(out, { t: 'fact', label: sprintf('Held %ds', button.holdSeconds), value: 'Factory reset: releases the gateway locally, wipes the overlay, and reboots.' });
            } else {
                push(out, { t: 'notice', tone: 'info', text: 'This board has no reset button wired up. A factory reset has to be done from the System page or over SSH.' });
            }
            return out;
        },
    };
};
