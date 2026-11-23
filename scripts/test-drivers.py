#!/usr/bin/env python3
"""pulzr-drivers against a stand-in for Pulzar, the broker and the firewall.

    UCODE=/path/to/ucode scripts/test-drivers.py

A ucode built with its fs module (scripts/check-ucode.sh says how; fs.so
beside the binary). net-api's POST /gateway-ops/drivers is a local HTTP
server; uci, nft and mosquitto_pub are stand-ins on the PATH that record what
they were given. Drivers run as this user (PULZR_DRIVERS_SANDBOX=none): the
uid, the fence and the limits are the gateway's, and `rules` is checked
instead.

What it shows:
  1. sync keeps the devices with a driver, throws away a driver whose bytes do
     not match its hash, refuses an address that is not one, and holds the
     credentials only in a root-only manifest; what it prints has none
  2. the fence lets each driver's uid reach its device's address and nothing
  3. a command is answered queued, then the driver's answer; the driver gets
     the address, the credentials and the opened secret on stdin, and the
     secret is in nothing published, logged or left on disk
  4. a key with no driver is left to its own module; an expired command and a
     wrong version are answered without running the driver; a driver with no
     answer, and a driver changed on disk, fail
  5. a device added at Pulzar is pulled before its first command
"""
import hashlib
import http.server
import json
import os
import pathlib
import shutil
import stat
import subprocess
import sys
import tempfile
import threading
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]
CLI = ROOT / 'feed/pulzr-drivers/files/usr/sbin/pulzr-drivers'
UCODE = shutil.which(os.environ.get('UCODE', 'ucode'))
if not UCODE:
    sys.exit('ucode not found; set UCODE=/path/to/ucode (built with its fs module)')

EUI = '9483c4fffe9aead1'
SECRET = 'opened-secret-Viewer-1'
ADMIN = 'camera-admin-pw'
failures = []


def check(what, ok, detail=''):
    print(f"{'ok  ' if ok else 'FAIL'} {what}" + ('' if ok else f': {detail}'))
    if not ok:
        failures.append(what)


DRIVER = r'''
import * as fs from 'fs';
let req = json(fs.stdin.read('all'));
let p = req.params ?? {};
if (req.name == 'echo') {
    print(sprintf('%J\n', { status: 'ok', data: {
        address: req.device.address, user: req.device.credentials?.username,
        admin: req.device.credentials?.password == 'camera-admin-pw',
        secret: p.password == 'opened-secret-Viewer-1', tmp: !!fs.stat(req.tmp) } }));
} else if (req.name == 'silent') {
    print('not json\n');
} else {
    print(sprintf('%J\n', { status: 'refused', reason: 'unknown', detail: 'no ' + req.name }));
}
'''
SHA = hashlib.sha256(DRIVER.encode()).hexdigest()
BAD_SHA = 'f' * 64

state = {'devices': [
    {'key': 'ext:camera.f0000610916b', 'address': '10.0.0.112', 'driver': SHA,
     'credentials': {'username': 'admin', 'password': ADMIN}},
    {'key': 'ext:camera.aabbccddeeff', 'address': '10.0.0.113; drop', 'driver': SHA, 'credentials': None},
    {'key': 'ext:camera.000000000001', 'address': '10.0.0.114', 'driver': BAD_SHA, 'credentials': None},
], 'asked': []}


class Pulzar(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        state['asked'].append(body)
        if self.path != '/api/v1/gateway-ops/drivers' or body.get('secret') != 'claim-secret':
            self.send_response(404)
            self.end_headers()
            return
        have = set(body.get('have') or [])
        drivers = {s: DRIVER for s in {SHA} - have}
        drivers[BAD_SHA] = DRIVER  # named by a hash it does not have
        out = json.dumps({'devices': state['devices'], 'drivers': drivers}).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def log_message(self, *a):
        pass


server = http.server.HTTPServer(('127.0.0.1', 0), Pulzar)
threading.Thread(target=server.serve_forever, daemon=True).start()

work = pathlib.Path(tempfile.mkdtemp(prefix='pulzr-drivers-'))
run_dir, claim, bin_dir, rec = work / 'run', work / 'claim', work / 'bin', work / 'rec'
for d in (claim, bin_dir, rec):
    d.mkdir()
(claim / 'id').write_text('ABCD-EFGH-JKMN\n')
(claim / 'secret').write_text('claim-secret\n')


def tool(name, body):
    p = bin_dir / name
    p.write_text('#!/bin/sh\n' + body)
    p.chmod(0o755)


modules = os.path.dirname(UCODE)
tool('ucode', f'exec {UCODE} -L {modules} "$@"\n')
tool('uci', f'''case "$3" in
pulzr.identity.gateway_eui) echo {EUI} ;;
pulzr.mqtt.host) echo broker.example ;;
pulzr.mqtt.username) echo gw ;;
pulzr.mqtt.password) echo broker-pw ;;
*) exit 1 ;;
esac
''')
tool('nft', f'cat > {rec}/nft.rules\n')
tool('mosquitto_pub', f'''while [ $# -gt 0 ]; do case "$1" in -t) t="$2"; shift ;; -f) f="$2"; shift ;; esac; shift; done
printf '%s %s\\n' "$t" "$(cat "$f")" >> {rec}/published
''')
if not shutil.which('sha256sum'):
    tool('sha256sum', 'exec shasum -a 256 "$@"\n')

env = {**os.environ, 'PATH': f'{bin_dir}:{os.environ["PATH"]}', 'PULZR_DRIVERS_RUN': str(run_dir),
       'PULZR_CLAIM_DIR': str(claim), 'PULZR_NET_URL': f'http://127.0.0.1:{server.server_port}',
       'PULZR_DRIVERS_UCODE': str(bin_dir / 'ucode'), 'PULZR_DRIVERS_SANDBOX': 'none'}
logs = []


def cli(*args, stdin=''):
    r = subprocess.run([str(bin_dir / 'ucode'), str(CLI), *args], input=stdin, capture_output=True, text=True,
                       env=env, timeout=60)
    logs.append(r.stderr)
    return r


def published():
    p = rec / 'published'
    lines = p.read_text().splitlines() if p.exists() else []
    p.unlink(missing_ok=True)
    return [(t, json.loads(b)) for t, b in (line.split(' ', 1) for line in lines)]


# 1. sync
r = cli('sync')
check('sync succeeds', r.returncode == 0, r.stdout + r.stderr)
out = json.loads(r.stdout)
check('sync asks with the claim secret and holds nothing yet', state['asked'][-1]['have'] == [])
check('it keeps the devices whose driver matches its hash',
      [d['key'] for d in out['devices']] == ['ext:camera.aabbccddeeff', 'ext:camera.f0000610916b'], out)
check('a driver named by the wrong hash is thrown away', not (run_dir / 'drivers' / f'{BAD_SHA}.uc').exists())
check('an address that is not one is refused', out['devices'][0]['address'] is None, out)
check('what it prints says there are credentials, not what they are',
      out['devices'][1]['credentials'] is True and ADMIN not in r.stdout, r.stdout)
manifest = run_dir / 'manifest.json'
check('the manifest is root-only', stat.S_IMODE(manifest.stat().st_mode) == 0o600, oct(manifest.stat().st_mode))
check('and holds the credentials, in RAM on a gateway', ADMIN in manifest.read_text())
check('the claim secret is not left on disk',
      not any('claim-secret' in p.read_text() for p in run_dir.rglob('*') if p.is_file()))
cli('sync')
check('a second sync names the driver it holds', state['asked'][-1]['have'] == [SHA], state['asked'][-1])

# 2. the fence
rules = (rec / 'nft.rules').read_text()
check('the fence is its own table, rebuilt whole',
      rules.startswith('table inet pulzr_drivers\ndelete table inet pulzr_drivers\n'), rules)
check('the driver uids jump to it', 'meta skuid 61000-61015 jump driver' in rules, rules)
check("each driver's uid reaches its device's address", 'meta skuid 61001 ip daddr 10.0.0.112 accept' in rules, rules)
check('a device with no address reaches nothing', 'skuid 61000 ' not in rules, rules)
check('and everything else is refused', rules.rstrip().endswith('reject\n\t}\n}'), rules)

# 3. a command
topic = f'pulzr/a/edge-{EUI}/d/ext:camera.f0000610916b/cmd'
cmd = {'v': 1, 'id': 'a' * 32, 'name': 'echo', 'params': {'username': 'site', 'password': SECRET},
       'expires': time.time() + 60}
r = cli('handle', topic, stdin=json.dumps(cmd))
res = published()
check('answered on cmd/res', [t for t, _ in res] == [topic + '/res'] * 2, res)
check('queued, then the driver\'s answer', [b['status'] for _, b in res] == ['queued', 'ok'], res)
data = res[-1][1].get('data') or {}
check('the driver gets the address and the credentials', (data.get('address'), data.get('user'), data.get('admin'))
      == ('10.0.0.112', 'admin', True), data)
check('and the opened secret, on stdin', data.get('secret') is True, data)
check('and its own scratch directory, emptied after', data.get('tmp') is True and
      not any((run_dir / 'tmp').iterdir()), list((run_dir / 'tmp').iterdir()))
check('the secret is in nothing published or logged',
      SECRET not in json.dumps(res) + ''.join(logs) + r.stdout, res)
# Outside the drivers, whose test source holds the literal it compares with.
check('nor left on disk', not any(SECRET in p.read_text() for p in run_dir.rglob('*')
                                  if p.is_file() and p.parent.name != 'drivers'))
check('the log names the command and its outcome', 'echo: ok' in r.stderr, r.stderr)

# 4. what is not run
r = cli('handle', f'pulzr/a/edge-{EUI}/d/modbus:{EUI}.rs485-0.1/cmd', stdin=json.dumps(cmd))
check("another module's key is left alone", published() == [] and r.stdout.strip() == 'null', r.stdout)
r = cli('handle', f'pulzr/a/edge-0011223344556677/d/ext:camera.f0000610916b/cmd', stdin=json.dumps(cmd))
check("another gateway's topic is left alone", published() == [], r.stdout)
cli('handle', topic, stdin=json.dumps({**cmd, 'expires': time.time() - 5}))
check('an expired command is not run', [b['status'] + ':' + b.get('reason', '') for _, b in published()]
      == ['failed:expired'])
cli('handle', topic, stdin=json.dumps({**cmd, 'v': 2}))
check('another protocol version is refused', [b.get('reason') for _, b in published()] == ['invalid'])
cli('handle', topic, stdin=json.dumps({**cmd, 'name': 'silent'}))
res = published()
check('a driver with no answer fails', (res[-1][1]['status'], res[-1][1]['reason']) == ('failed', 'error'), res)
cli('handle', topic, stdin=json.dumps({**cmd, 'name': 'user.nothing'}))
check("a driver's refusal goes back as it said it",
      [(b['status'], b.get('reason')) for _, b in published()][-1] == ('refused', 'unknown'))
driver = run_dir / 'drivers' / f'{SHA}.uc'
driver.write_text(DRIVER + '\n// changed\n')
cli('handle', topic, stdin=json.dumps(cmd))
res = published()
check('a driver changed on disk is not run', 'does not match' in res[-1][1].get('detail', ''), res)

# 5. a device added at Pulzar
state['devices'].append({'key': 'ext:camera.0000000000aa', 'address': '10.0.0.115', 'driver': SHA,
                         'credentials': None})
before = len(state['asked'])
cli('handle', 'pulzr/a/edge-%s/d/ext:camera.0000000000aa/cmd' % EUI, stdin=json.dumps(cmd))
res = published()
check('a device the gateway did not know is pulled before its command',
      len(state['asked']) > before and [b['status'] for _, b in res] == ['queued', 'ok'], res)
check('and its driver restored from Pulzar', hashlib.sha256(driver.read_bytes()).hexdigest() == SHA)

server.shutdown()
shutil.rmtree(work)
if failures:
    sys.exit(f'{len(failures)} failed')
print('pulzr-drivers: ok')
