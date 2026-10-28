// A stand-in for ucode's uci module that keeps the config in one JSON file
// ($UCI_JSON), for scripts/test-router.sh. Only what parkeze-dns and
// parkeze-uplinks call: get, get_all, set, delete, foreach, commit.
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
        delete: function(p, s, o) {
            if (o == null) delete db[p][s];
            else if (db[p]?.[s]) delete db[p][s][o];
            return true;
        },
        foreach: function(p, t, fn) {
            for (let n in keys(db[p] ?? {})) if (db[p][n]['.type'] == t) fn(db[p][n]);
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
