{%
// Serves /assets/* — the console's own JS and CSS chunks, precompressed by
// build.sh — with gzip when the browser will take it.
//
// uhttpd has no gzip support at all (checked the binary: no Content-Encoding,
// no .gz-sidecar handling, nothing). Mounted as its own ucode_prefix rather
// than folded into api/index.uc, because claiming /assets here means uhttpd's
// own static handler never sees it again — every request under this prefix
// has to be answered from here, including the plain, no-compression case, or
// the whole console stops loading.
//
// See api/index.uc's own header comment for the handle_request contract this
// follows (bare global assignment, not a module, uhttpd.send() with a
// "Status:" line).
//
// ── THE ONE THING THAT COST AN AFTERNOON ────────────────────────────────────
//
// sprintf('...%s', data) with a gzip file's raw bytes as the %s argument hung
// the connection forever — no response, no error, no log line, uhttpd still
// running. Building the header text with sprintf and then concatenating the
// binary body on with += , as below, works and round-trips byte-for-byte
// (checked with cmp against the source file). Whatever sprintf's %s does to
// its argument, it is not safe for four figures of arbitrary bytes; string
// concatenation is just a copy and does not touch them.

let _fs = require('fs');

const ROOT = '/www/pulzr/assets';

const CONTENT_TYPES = {
    '.js': 'text/javascript',
    '.css': 'text/css',
    '.json': 'application/json',
    '.svg': 'image/svg+xml',
    '.png': 'image/png',
    '.woff2': 'font/woff2',
};

function contentType(name) {
    const dot = rindex(name, '.');
    return dot >= 0 ? (CONTENT_TYPES[substr(name, dot)] ?? 'application/octet-stream')
                     : 'application/octet-stream';
}

// uhttpd's CGI-style "Status:" header wants "<code> <reason>", not a bare
// code — without the reason phrase it silently defaulted to 200 regardless
// of what status was actually sent, which is how a missing asset briefly
// answered 200 with a "Not found" body instead of a real 404.
const STATUS_TEXT = { '200': 'OK', '404': 'Not Found', '500': 'Internal Server Error' };

function send(status, headers, body) {
    let out = sprintf('Status: %d %s\r\n', status, STATUS_TEXT[sprintf('%d', status)] ?? 'OK');
    for (let k in headers) out += sprintf('%s: %s\r\n', k, headers[k]);
    out += sprintf('Content-Length: %d\r\n\r\n', length(body ?? ''));
    // Binary-safe only because the body never goes through sprintf's %s —
    // see the header comment.
    if (body) out += body;
    uhttpd.send(out);
}

handle_request = function(env) {
    try {
        const name = substr(env.PATH_INFO ?? '', 1);

        // One path segment, Vite's own naming convention and nothing else —
        // no '/', no '..', no reading outside this directory. Reject rather
        // than sanitise: a name this does not match has no business here.
        if (!name || !match(name, /^[A-Za-z0-9][A-Za-z0-9._-]*$/)) {
            send(404, { 'Content-Type': 'text/plain' }, 'Not found\n');
            return;
        }

        const path = ROOT + '/' + name;
        const acceptsGzip = index(env.headers?.['accept-encoding'] ?? '', 'gzip') >= 0;

        // These filenames carry a content hash (index-<hash>.js) — a changed
        // file is a new URL, so there is nothing this cache can ever serve
        // stale, and a year is standard for that reason.
        const headers = {
            'Content-Type': contentType(name),
            'Cache-Control': 'public, max-age=31536000, immutable',
        };

        if (acceptsGzip) {
            const gz = _fs.readfile(path + '.gz');
            if (gz) {
                send(200, { ...headers, 'Content-Encoding': 'gzip' }, gz);
                return;
            }
        }

        const plain = _fs.readfile(path);
        if (plain) {
            send(200, headers, plain);
            return;
        }

        send(404, { 'Content-Type': 'text/plain' }, 'Not found\n');
    }
    catch (e) {
        warn(sprintf('pulzr-console assets: %s\n%s\n', e.message ?? e, e.stacktrace ?? ''));
        send(500, { 'Content-Type': 'text/plain' }, 'Internal error\n');
    }
};
%}
