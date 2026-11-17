// ucode's socket module for scripts/test-wifi-uplink.sh: a DNS server per
// address, as $FAKE_DNS says ("10.0.0.1=drop,10.0.0.2=a:1.2.3.4").
//
//   drop    never answers
//   nx      NXDOMAIN
//   a:IP    the address
//   tc:IP   truncated over UDP; the address over TCP
//
// Each question is a line in $T/dns: "<udp|tcp> <server>".
let fs = require('fs');

let behaviour = (server) => {
    for (let pair in split(getenv('FAKE_DNS') ?? '', ','))
        if (split(pair, '=')[0] == server) return split(pair, '=')[1];
    return 'drop';
};

let be16 = (n) => chr((n >> 8) & 255, n & 255);

let reply = (query, flags, ip) => {
    let out = substr(query, 0, 2) + chr(flags >> 8, flags & 255) + be16(1) + be16(ip ? 1 : 0) + be16(0) + be16(0);
    out += substr(query, 12);
    if (ip) {
        out += chr(0xc0, 12) + be16(1) + be16(1) + be16(0) + be16(60) + be16(4);
        for (let b in split(ip, '.')) out += chr(int(b));
    }
    return out;
};

function create(domain, kind) {
    return {
        kind, server: null, query: null,
        setopt: () => true,
        connect: function(host, port) { this.server = host; return true; },
        send: function(data) {
            this.query = this.kind == 1 ? substr(data, 2) : data;
            let log = fs.open(getenv('T') + '/dns', 'a');
            log.write(sprintf('%s %s\n', this.kind == 1 ? 'tcp' : 'udp', this.server));
            log.close();
            return length(data);
        },
        recv: function(size) {
            let b = behaviour(this.server), m = match(b, /^(a|tc):(.*)$/), out = null;
            if (b == 'nx') out = reply(this.query, 0x8183, null);
            else if (m && m[1] == 'a') out = reply(this.query, 0x8180, m[2]);
            else if (m && this.kind == 1) out = reply(this.query, 0x8180, m[2]);
            else if (m) out = reply(this.query, 0x8380, null);
            if (out == null || this.done) return null;
            this.done = true;
            return this.kind == 1 ? be16(length(out)) + out : out;
        },
        close: () => true,
    };
}

return { AF_INET: 2, SOCK_STREAM: 1, SOCK_DGRAM: 2, SOL_SOCKET: 1, SO_BINDTODEVICE: 25,
         SO_RCVTIMEO: 20, SO_SNDTIMEO: 21, create };
