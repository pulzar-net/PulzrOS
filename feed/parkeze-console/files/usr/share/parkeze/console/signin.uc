{%
// The WiFi sign-in proxy: a portal's pages, fetched out of the WiFi radio and
// handed to a browser on lib/signin.uc's SIGNIN_PORT. What it is for, why it
// has a port of its own and when it answers are in lib/signin.uc.
//
// See api/index.uc's header for the handle_request contract (template mode, a
// bare global, uhttpd.send() with a "Status:" line), and assets.uc's for why a
// binary body is concatenated on rather than passed through sprintf.
//
// ── THE URLS ───────────────────────────────────────────────────────────────
//
//   /signin/session?t=<ticket>              trade a ticket for this origin's cookie
//   /signin/                                the network's sign-in page
//   /signin/trust?host=<h>&next=<path>      accept a certificate, as a browser asks
//   /signin/<http|https>/<host[:port]>/...  that URL, fetched over WiFi
//
// A portal's links are rewritten into the last form: absolute and
// root-relative URLs in HTML attributes and CSS, Location headers, and
// fetch/XHR/window.open through a small script put at the top of each page.
// Relative links need nothing — the browser resolves them against a URL that
// already has the right shape. What this cannot follow is a script that
// builds an absolute URL and assigns it to location; such a portal does not
// load here.
//
// ── WHAT IS NEVER PASSED ON ────────────────────────────────────────────────
//
// The browser's cookies — on a local address it holds the console's session —
// its Authorization, and every header not in FORWARDED. The portal's cookies
// stay on the gateway, in one jar: it is the gateway being signed in, not the
// browser.

let _m_fs = require('fs');
let readfile = _m_fs.readfile;
let writefile = _m_fs.writefile;
let unlink = _m_fs.unlink;
let popen = _m_fs.popen;
let signin = loadfile('/usr/share/parkeze/console/lib/signin.uc', { raw_mode: true })();
let _m_util = loadfile('/usr/share/parkeze/console/lib/util.uc', { raw_mode: true })();

// ucode does not hoist function declarations; see util.uc.
let send, page, cookieOf, urlencode, urldecode, proxify, rewriteCss, rewriteHtml;
let resolveHost, forbidden, tmpName, quoted, upstreamReferer, fetch, route;

const DIR = '/tmp/parkeze-signin';
const JAR = DIR + '/jar';
const MAX_BODY = 256 * 1024;
const COOKIE = 'parkeze_signin';

// Request headers a portal sees. Content-Type only with a body.
const FORWARDED = { 'user-agent': 'User-Agent', 'accept': 'Accept',
                    'accept-language': 'Accept-Language' };

const STATUS_TEXT = {
    '200': 'OK', '201': 'Created', '204': 'No Content', '301': 'Moved Permanently',
    '302': 'Found', '303': 'See Other', '304': 'Not Modified',
    '307': 'Temporary Redirect', '308': 'Permanent Redirect', '400': 'Bad Request',
    '401': 'Unauthorized', '403': 'Forbidden', '404': 'Not Found',
    '405': 'Method Not Allowed', '409': 'Conflict', '413': 'Payload Too Large',
    '500': 'Internal Server Error', '502': 'Bad Gateway', '503': 'Service Unavailable',
};

// On every answer. Referrer-Policy is same-origin, not no-referrer like the
// console's: a portal that checks Referer gets one, translated back from this
// origin's URLs, and nothing leaves for another site.
const BASE_HEADERS = {
    'X-Content-Type-Options': 'nosniff',
    'Cache-Control': 'no-store',
    'Referrer-Policy': 'same-origin',
    'Content-Security-Policy': "frame-ancestors 'none'",
};

// Put at the top of every proxied page. Double quotes and no backslashes, so
// it needs no escaping inside this single-quoted string.
const SHIM = '<script>(function(){'
    + 'var p=location.pathname.split("/");if(p[1]!=="signin")return;var S=p[2],A=p[3];'
    + 'function cut(r){var k=r.length,c=["/","?","#"];for(var n=0;n<3;n++){var x=r.indexOf(c[n]);if(x>=0&&x<k)k=x}return k}'
    + 'function m(u){if(typeof u!=="string")return u;var l=u.toLowerCase();'
    + 'if(l.indexOf("http://")===0||l.indexOf("https://")===0){var i=u.indexOf("://"),r=u.slice(i+3),k=cut(r),t=r.slice(k);'
    + 'return "/signin/"+l.slice(0,i)+"/"+r.slice(0,k).toLowerCase()+(t.charAt(0)==="/"?t:"/"+t)}'
    + 'if(u.slice(0,2)==="//")return m(S+":"+u);'
    + 'if(u.charAt(0)==="/"&&u.indexOf("/signin/")!==0)return "/signin/"+S+"/"+A+u;return u}'
    + 'var f=window.fetch;if(f)window.fetch=function(i,o){return f.call(this,m(i),o)};'
    + 'var X=XMLHttpRequest.prototype,o=X.open;X.open=function(){var a=[].slice.call(arguments);a[1]=m(String(a[1]));return o.apply(this,a)};'
    + 'var w=window.open;window.open=function(){var a=[].slice.call(arguments);a[0]=m(a[0]);return w.apply(this,a)};'
    + '})();</script>';

send = function(status, headers, body) {
    let out = sprintf('Status: %d %s\r\n', status, STATUS_TEXT[sprintf('%d', status)] ?? 'Status');
    for (let k in headers) out += sprintf('%s: %s\r\n', k, headers[k]);
    out += sprintf('Content-Length: %d\r\n\r\n', length(body ?? ''));
    // Binary-safe only because the body never goes through sprintf's %s.
    if (body) out += body;
    uhttpd.send(out);
};

// One sentence, and a link when there is something to do about it.
page = function(status, message, link) {
    const esc = (t) => replace(replace(replace(t, /&/g, '&amp;'), /</g, '&lt;'), /"/g, '&quot;');
    let html = '<!doctype html><meta charset="utf-8">'
        + '<meta name="viewport" content="width=device-width,initial-scale=1">'
        + '<title>WiFi sign-in</title>'
        + '<style>body{font:15px/1.5 system-ui,sans-serif;margin:3rem auto;max-width:32rem;padding:0 1rem}</style>'
        + '<p>' + esc(message) + '</p>';
    if (link) html += '<p><a href="' + esc(link.href) + '">' + esc(link.text) + '</a></p>';
    send(status, { ...BASE_HEADERS, 'Content-Type': 'text/html; charset=utf-8' }, html);
};

cookieOf = function(env, name) {
    for (let pair in split(env.headers?.cookie ?? '', ';')) {
        const eq = index(pair, '=');
        if (eq > 0 && trim(substr(pair, 0, eq)) == name) return trim(substr(pair, eq + 1));
    }
    return null;
};

urlencode = function(text) {
    return replace(text, /[^A-Za-z0-9._~\/-]/g, (c) => sprintf('%%%02X', ord(c)));
};

urldecode = function(text) {
    return replace(text, /%([0-9A-Fa-f]{2})/g, (all, h) => chr(hex(h)));
};

// A URL in a portal's page, as the path that fetches it through here. base is
// { scheme, authority } of the page it came from. Relative URLs, fragments and
// data:, javascript: and mailto: links come back unchanged.
proxify = function(url, base) {
    const u = trim(url);
    const m = match(u, /^(https?):\/\/([A-Za-z0-9.-]+(:[0-9]+)?)(.*)$/i);
    if (m) {
        const rest = m[4] ?? '';
        return '/signin/' + lc(m[1]) + '/' + lc(m[2])
            + (substr(rest, 0, 1) == '/' ? rest : '/' + rest);
    }
    if (substr(u, 0, 2) == '//') return proxify(base.scheme + ':' + u, base);
    if (substr(u, 0, 1) == '/') return '/signin/' + base.scheme + '/' + base.authority + u;
    return url;
};

rewriteCss = function(text, base) {
    return replace(text, /url\(\s*(["']?)([^"')]+)["']?\s*\)/gi, (all, q, url) => {
        const p = proxify(url, base);
        // Untouched when there is nothing to map: a data: URL can hold the
        // very quotes and parentheses this pattern stops at. Otherwise quoted
        // as it was, because this also runs over style="" attributes, where
        // a double quote would end the attribute.
        return p == url ? all : 'url(' + q + p + q + ')';
    });
};

rewriteHtml = function(text, base) {
    let html = text;
    // The portal's own policy names the hosts it expects to load from, none
    // of which are this one. Integrity hashes would fail on the stylesheets
    // rewritten below.
    html = replace(html, /<meta[^>]+http-equiv\s*=\s*["']?content-security-policy[^>]*>/gi, '');
    html = replace(html, /\sintegrity\s*=\s*("[^"]*"|'[^']*')/gi, '');

    html = replace(html,
        /(\s(href|src|action|formaction|poster|background)\s*=\s*)("[^"]*"|'[^']*'|[^\s"'>]+)/gi,
        (all, pre, name, value) => {
            const q = substr(value, 0, 1);
            if (q == '"' || q == "'")
                return pre + q + proxify(substr(value, 1, length(value) - 2), base) + q;
            return pre + proxify(value, base);
        });
    html = replace(html,
        /(<meta[^>]+content\s*=\s*["']\s*[0-9]+\s*;\s*url\s*=\s*)([^"'>]+)/gi,
        (all, pre, url) => pre + proxify(url, base));
    html = rewriteCss(html, base);

    const head = match(html, /<head[^>]*>/i);
    if (!head) return SHIM + html;
    const at = index(html, head[0]) + length(head[0]);
    return substr(html, 0, at) + SHIM + substr(html, at);
};

// A host's IPv4 address as the WiFi network answers it: asked of the WiFi's
// own DNS servers, out of the WiFi device. Not the gateway's resolver, which
// may ask over cellular and get the real address where a portal answers with
// its own. See parkeze-wifi-resolve.
resolveHost = function(host) {
    if (match(host, /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/)) return host;
    if (!match(host, /^[a-z0-9.-]+$/)) return null;
    return _m_util.run(sprintf("/usr/sbin/parkeze-wifi-resolve '%s' 2>/dev/null", host)) || null;
};

// This gateway itself, loopback, link-local and multicast. Bound to the WiFi
// device, a request for one of the gateway's own addresses is still local
// delivery, and the proxy would be a way to its loopback-only services.
forbidden = function(ip) {
    if (match(ip, /^(127|0)\./) || match(ip, /^169\.254\./)) return true;
    if (int(split(ip, '.')[0]) >= 224) return true;
    const own = _m_util.run('ip -4 -o addr show 2>/dev/null') || '';
    return match(own, regexp('inet ' + replace(ip, /\./g, '\\.') + '/')) != null;
};

tmpName = function(kind) {
    return DIR + '/' + kind + '-' + replace(readfile('/proc/sys/kernel/random/uuid') || '', /[^0-9a-f]/g, '');
};

// A value in curl's config-file syntax. Nothing from a browser reaches a
// shell: it goes into a file curl reads with -K.
quoted = function(value) {
    return '"' + replace(replace(replace('' + value, /[\r\n]/g, ''), /\\/g, '\\\\'), /"/g, '\\"') + '"';
};

// The browser's Referer — one of this origin's URLs — as the portal URL it
// stands for.
upstreamReferer = function(env) {
    const m = match(env.headers?.referer ?? '',
                    /^https?:\/\/[^\/]+\/signin\/(https?)\/([A-Za-z0-9.-]+(:[0-9]+)?)([\/?][^#]*)?/);
    if (!m) return null;
    return { origin: m[1] + '://' + m[2], url: m[1] + '://' + m[2] + (m[4] ?? '/') };
};

fetch = function(env, s, scheme, authority, rest) {
    const method = env.REQUEST_METHOD;
    if (method != 'GET' && method != 'POST' && method != 'HEAD')
        return page(405, 'Only GET and POST go through here.');

    const host = lc(split(authority, ':')[0]);
    const colon = index(authority, ':');
    const port = colon >= 0 ? int(substr(authority, colon + 1)) : (scheme == 'https' ? 443 : 80);
    if (port < 1 || port > 65535) return page(400, 'That address has no valid port.');

    const wifi = _m_util.runJson('ubus call network.interface.wwifi status') || {};
    const dev = wifi.l3_device;
    if (!wifi.up || !dev || !match(dev, /^[A-Za-z0-9._-]+$/))
        return page(503, 'The WiFi network is not connected.');

    const ip = resolveHost(host);
    if (!ip) return page(502, host + ' does not resolve on the WiFi network.');
    if (forbidden(ip)) return page(403, host + ' is this gateway, not the network.');

    const conf = tmpName('conf'), reqBody = tmpName('body'),
          hdr = tmpName('head'), out = tmpName('out');
    const upstream = scheme + '://' + authority + rest;
    const lines = [
        'silent', 'ipv4', 'globoff', 'compressed',
        'url = ' + quoted(upstream),
        'resolve = ' + quoted(sprintf('%s:%d:%s', host, port, ip)),
        'interface = ' + quoted(dev),
        'cookie = ' + quoted(JAR),
        'cookie-jar = ' + quoted(JAR),
        'dump-header = ' + quoted(hdr),
        'output = ' + quoted(out),
        'max-filesize = 4194304',
        'connect-timeout = 10',
        'max-time = 30',
        'write-out = "%{http_code}"',
    ];
    for (let k in FORWARDED)
        if (env.headers?.[k]) push(lines, 'header = ' + quoted(FORWARDED[k] + ': ' + env.headers[k]));
    const ref = upstreamReferer(env);
    if (ref) push(lines, 'header = ' + quoted('Referer: ' + ref.url));

    if (method == 'POST') {
        const len = int(env.CONTENT_LENGTH ?? 0);
        if (len > MAX_BODY) return page(413, 'That form is too large to send.');
        let raw = '';
        while (length(raw) < len) {
            const chunk = uhttpd.recv(len - length(raw));
            if (chunk == null || !length(chunk)) break;
            raw += chunk;
        }
        writefile(reqBody, raw);
        push(lines, 'data-binary = ' + quoted('@' + reqBody));
        if (env.headers?.['content-type'])
            push(lines, 'header = ' + quoted('Content-Type: ' + env.headers['content-type']));
        // Browsers send Origin with a POST and portals that guard their forms
        // check it.
        if (ref) push(lines, 'header = ' + quoted('Origin: ' + ref.origin));
    }
    if (index(s.trust ?? [], host) >= 0) push(lines, 'insecure');

    writefile(conf, join('\n', lines) + '\n');
    const proc = popen(sprintf("curl -K '%s' 2>/dev/null", conf), 'r');
    const code = proc ? trim(proc.read('all') ?? '') : '';
    const rc = proc ? proc.close() : -1;
    const head = readfile(hdr) || '';
    let body = readfile(out) || '';
    for (let f in [conf, reqBody, hdr, out]) unlink(f);

    if (rc == 51 || rc == 60)
        return page(502, host + ' presented a certificate this gateway does not trust.',
                    { href: '/signin/trust?host=' + urlencode(host) + '&next=' + urlencode(env.REQUEST_URI),
                      text: 'Continue to ' + host });
    if (rc == 63) return page(502, 'That page is larger than 4 MB.');
    if (rc != 0) return page(502, 'No answer from ' + host + ' over WiFi.');

    // The last block of headers: a 100 Continue comes first when a form was
    // sent.
    const blocks = split(trim(head), /\r?\n\r?\n/);
    const hlines = split(blocks[length(blocks) - 1], /\r?\n/);
    const status = int(match(hlines[0] ?? '', /^HTTP\/[0-9.]+ ([0-9]{3})/)?.[1] ?? code);
    const h = {};
    for (let i = 1; i < length(hlines); i++) {
        const c = index(hlines[i], ':');
        if (c > 0) h[lc(trim(substr(hlines[i], 0, c)))] = trim(substr(hlines[i], c + 1));
    }

    const base = { scheme: scheme, authority: authority };
    const headers = { ...BASE_HEADERS, 'Content-Type': h['content-type'] ?? 'application/octet-stream' };
    if (h['location']) headers['Location'] = proxify(h['location'], base);
    if (h['content-disposition']) headers['Content-Disposition'] = h['content-disposition'];

    const type = lc(headers['Content-Type']);
    const text = index(type, 'text/html') == 0 || index(type, 'text/css') == 0;
    if (index(type, 'text/html') == 0) {
        body = rewriteHtml(body, base);
        warn(sprintf('wifi-signin: %s %s://%s -> %d\n', method, scheme, authority, status));
    } else if (index(type, 'text/css') == 0) {
        body = rewriteCss(body, base);
    }

    // Text is compressed on the way back, because the way back is often a SIM.
    if (text && length(body) > 1024
        && index(env.headers?.['accept-encoding'] ?? '', 'gzip') >= 0) {
        const plain = tmpName('gz');
        writefile(plain, body);
        const gz = popen(sprintf("gzip -c '%s'", plain), 'r');
        const packed = gz ? gz.read('all') : null;
        if (gz && gz.close() == 0 && packed) {
            body = packed;
            headers['Content-Encoding'] = 'gzip';
            headers['Vary'] = 'Accept-Encoding';
        }
        unlink(plain);
    }

    send(status, headers, method == 'HEAD' ? '' : body);
};

route = function(env) {
    const uri = env.REQUEST_URI ?? '/signin/';
    const q = index(uri, '?');
    const path = q >= 0 ? substr(uri, 0, q) : uri;
    const query = q >= 0 ? substr(uri, q + 1) : '';

    if (path == '/signin/session') {
        const t = match(query, /(^|&)t=([0-9a-f]{64})(&|$)/);
        const id = t ? signin.redeem(t[2]) : null;
        if (!id) return page(403, 'That sign-in link has been used or has expired. Start again from the console.');
        return send(302, {
            ...BASE_HEADERS,
            'Set-Cookie': sprintf('%s=%s; Path=/signin; Max-Age=1800; HttpOnly; Secure; SameSite=Lax',
                                  COOKIE, id),
            'Location': '/signin/',
        }, '');
    }

    const s = signin.session(cookieOf(env, COOKIE));
    if (!s) return page(401, 'Not signed in. Start from the gateway console.');
    const can = signin.available();
    if (can.error) return page(409, can.error);

    if (path == '/signin' || path == '/signin/') {
        if (!can.uplink.url) return page(409, 'The WiFi network has not asked for a sign-in.');
        return send(302, { ...BASE_HEADERS,
                           'Location': proxify(can.uplink.url, { scheme: 'http', authority: '' }) }, '');
    }

    if (path == '/signin/trust') {
        const host = match(query, /(^|&)host=([a-z0-9.-]+)(&|$)/);
        const next = match(query, /(^|&)next=([^&]*)/);
        const target = next ? urldecode(next[2]) : '';
        if (!host || index(target, '/signin/https/' + host[2]) != 0 || match(target, /[\r\n]/))
            return page(400, 'That link is not one this gateway made.');
        signin.trust(s, host[2]);
        return send(302, { ...BASE_HEADERS, 'Location': target }, '');
    }

    const m = match(uri, /^\/signin\/(https?)\/([A-Za-z0-9.-]+(:[0-9]+)?)([\/?].*)?$/);
    if (!m) return page(404, 'Not a sign-in address.');
    let rest = m[4] ?? '/';
    if (substr(rest, 0, 1) == '?') rest = '/' + rest;
    return fetch(env, s, m[1], lc(m[2]), rest);
};

handle_request = function(env) {
    try {
        route(env);
    }
    catch (e) {
        warn(sprintf('wifi-signin: %s\n%s\n', e.message ?? e, e.stacktrace ?? ''));
        send(500, { 'Content-Type': 'text/plain' }, 'Internal error\n');
    }
};
%}
