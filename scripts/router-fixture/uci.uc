// A stand-in for ucode's uci module that keeps the config in one JSON file
// ($UCI_JSON), for scripts/test-router.sh and scripts/test-wifi-uplink.sh.
// Only what pulzr-dns, pulzr-uplinks, pulzr-lan and the console's access.uc
// call: get, get_all, set, add, delete, foreach, reorder, commit. foreach's
// sections carry '.index', their position in the config, as ucode's do.
let fs = require('fs');
let path = getenv('UCI_JSON');

function load() { return json(fs.readfile(path) ?? '{}'); }

function cursor() {
    let db = load();
    return {
        get: function(p, s, o) {
            let sec = db[p]?.[s];
            if (!sec) return null;
            return o == null ? sec['.type'] : sec[o];
        },
        get_all: function(p, s) { return db[p]?.[s]; },
        set: function(p, s, o, v) {
            db[p] ??= {};
            if (v == null) { db[p][s] = { '.type': o, '.name': s }; return true; }
            db[p][s][o] = v;
            return true;
        },
        add: function(p, t) {
            db[p] ??= {};
            let n = 0;
            while (db[p][sprintf('cfg%02x', n)]) n++;
            let name = sprintf('cfg%02x', n);
            db[p][name] = { '.type': t, '.name': name };
            return name;
        },
        delete: function(p, s, o) {
            if (!db[p]) return true;
            if (o == null) delete db[p][s];
            else if (db[p]?.[s]) delete db[p][s][o];
            return true;
        },
        foreach: function(p, t, fn) {
            let names = keys(db[p] ?? {});
            for (let i = 0; i < length(names); i++)
                if (db[p][names[i]]['.type'] == t) {
                    db[p][names[i]]['.index'] = i;
                    fn(db[p][names[i]]);
                    delete db[p][names[i]]['.index'];
                }
        },
        reorder: function(p, s, at) {
            let names = filter(keys(db[p] ?? {}), (n) => n != s), out = {};
            if (!db[p]?.[s]) return false;
            splice(names, at, 0, s);
            for (let n in names) out[n] = db[p][n];
            db[p] = out;
            return true;
        },
        commit: function(p) {
            let disk = load();
            disk[p] = db[p];
            fs.writefile(path, sprintf('%.J', disk));
            return true;
        },
    };
}

return { cursor };
