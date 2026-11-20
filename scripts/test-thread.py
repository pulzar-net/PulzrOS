#!/usr/bin/env python3
"""Two Thread border routers and a device, simulated, driven through
pulzr-thread as a gateway runs it.

    sudo scripts/test-thread.py <sim-dir>     (scripts/thread-sim.sh builds it)

Each border router is otbr-agent, at the commit OpenWrt's openthread-br is
built from, in a network and mount namespace of its own (its own wpan0,
loopback REST API, /run and /var/lib/thread), with the isolated backbone a
gateway uses by default and the command line init.d/pulzr-thread gives it. Its
radio is OpenThread's simulated RCP, run in the root namespace behind a pty so
that every simulated radio hears every other. The device is OpenThread's
simulated FTD CLI, kept a child.

What it shows, in order:
  1. form: the first border router starts a network from a dataset made the
     way the platform makes one, and leads it
  2. join: the second joins with the same dataset and becomes a router
  3. permit: the device joins by commissioning (its PSKd), not by a dataset
  4. the device reports to a listener on the border router it is NOT the
     child of, every two seconds
  5. its parent border router is stopped, radio and all; the device finds the
     other one and keeps reporting
  6. topology from the survivor names the device under it
  7. the network key is in no output but `dataset`'s, and the REST API is on
     loopback only
  8. leave erases the network from the survivor
"""
import hashlib
import json
import os
import pathlib
import queue
import secrets
import shutil
import signal
import subprocess
import sys
import threading
import time

SIM = pathlib.Path(sys.argv[1]).resolve()
ROOT = pathlib.Path(__file__).resolve().parents[1]
CLI = ROOT / 'feed/pulzr-thread/files/usr/sbin/pulzr-thread'
WORK = pathlib.Path('/tmp/thread-sim')
EUI = {'br1': 'b827ebfffe000001', 'br2': 'b827ebfffe000002'}
PSKD = 'J01NME'

procs = []
failures = []


def log(*a):
    print('[test-thread]', *a, flush=True)


def check(name, ok, detail=''):
    log(('PASS ' if ok else 'FAIL ') + name + (f': {detail}' if detail and not ok else ''))
    if not ok:
        failures.append(name)


def sh(*cmd, check_rc=True, **kw):
    r = subprocess.run(cmd, capture_output=True, text=True, **kw)
    if check_rc and r.returncode != 0:
        raise RuntimeError(f'{cmd}: {r.returncode}\n{r.stdout}\n{r.stderr}')
    return r


def spawn(*cmd, **kw):
    p = subprocess.Popen(cmd, **kw)
    procs.append(p)
    return p


# ── a dataset as the platform makes one ─────────────────────────────────────

def tlv(t, value):
    return bytes([t, len(value)]) + value


def make_dataset(channel):
    """Every TLV a complete active dataset carries, random where Thread wants
    it random. The platform's own generator (net-api utils/thread.py) is the
    same shape; this test only needs one that OpenThread accepts unchanged."""
    pan = secrets.token_bytes(2)
    xpan = secrets.token_bytes(8)
    ml = bytes([0xfd]) + secrets.token_bytes(5) + b'\x00\x00'
    name = f'Pulzr-{pan.hex()}'.encode()
    now = int(time.time())
    return b''.join([
        tlv(14, (now << 16).to_bytes(8, 'big')),
        tlv(0, bytes([0]) + channel.to_bytes(2, 'big')),
        tlv(53, bytes.fromhex('0004001fffe0')),
        tlv(2, xpan),
        tlv(7, ml),
        tlv(5, secrets.token_bytes(16)),
        tlv(3, name),
        tlv(1, pan),
        tlv(4, secrets.token_bytes(16)),
        tlv(12, bytes.fromhex('02a0f7f8')),
    ])


def parse(ds):
    out, i = [], 0
    while i < len(ds):
        t, n = ds[i], ds[i + 1]
        out.append((t, ds[i:i + 2 + n]))
        i += 2 + n
    return out


def dataset_id(ds):
    """pulzr-protocol's dataset_id: SHA-256 of the naming TLVs (channel, PAN
    id, extended PAN id, name, mesh-local prefix, active timestamp), sorted by
    type."""
    kept = sorted((t, raw) for t, raw in parse(ds) if t in (0, 1, 2, 3, 7, 14))
    return hashlib.sha256(b''.join(raw for _, raw in kept)).hexdigest()[:16]


# ── a border router ─────────────────────────────────────────────────────────

class BorderRouter:
    def __init__(self, name, node):
        self.name, self.node = name, node
        self.dir = WORK / name
        self.dir.mkdir(parents=True)
        (self.dir / 'uci').mkdir()
        self.uci_set('pulzr_thread.main.radio', f'usb-1915_cafe-sim{node}')
        self.uci_set('pulzr_thread.main.enabled', '1')
        self.uci_set('pulzr.identity.gateway_eui', EUI[name])
        (self.dir / 'probe').mkdir()
        sh('ip', 'netns', 'add', name)
        # A holder process whose namespaces everything else joins: its own
        # network, and its own /run and /var/lib/thread, where otbr-agent puts
        # its socket and settings.
        self.holder = spawn('ip', 'netns', 'exec', name, 'unshare', '-m', '--propagation', 'private',
                            'sh', '-c', 'mount -t tmpfs none /run && mkdir -p /var/lib/thread && '
                            'mount -t tmpfs none /var/lib/thread && exec sleep infinity')
        time.sleep(1)
        self.ns('ip', 'link', 'set', 'lo', 'up')
        # The isolated backbone, as init.d/pulzr-thread makes it.
        self.ns('ip', 'link', 'add', 'thread-bb', 'type', 'dummy')
        self.ns('ip', 'link', 'set', 'thread-bb', 'multicast', 'on', 'up')

        self.pty = WORK / f'rcp{node}'
        self.rcp = spawn('socat', f'pty,raw,echo=0,link={self.pty}', f'EXEC:{SIM}/ot-rcp {node}',
                         stdout=open(self.dir / 'rcp.log', 'w'), stderr=subprocess.STDOUT)
        for _ in range(50):
            if self.pty.exists():
                break
            time.sleep(0.1)
        (self.dir / 'probe' / 'radios.json').write_text(json.dumps({'detected': [{
            'id': f'usb-1915_cafe-sim{node}', 'path': os.path.realpath(self.pty), 'bus': 'usb',
            'protocol': 'thread', 'protocols': ['thread'], 'state': 'free'}]}))
        url = self.cli('radio-url').strip()
        # init.d/pulzr-thread's command line for the isolated backbone.
        self.agent = spawn('nsenter', '-t', str(self.holder.pid), '-n', '-m', '--',
                           f'{SIM}/otbr-agent', '-I', 'wpan0', '-B', 'thread-bb',
                           '--rest-listen-address', '127.0.0.1', '-v', url,
                           stdout=open(self.dir / 'otbr.log', 'w'), stderr=subprocess.STDOUT)
        for _ in range(60):
            if self.ns('curl', '-s', 'http://127.0.0.1:8081/node/state', check_rc=False).returncode == 0:
                break
            time.sleep(0.5)
        else:
            raise RuntimeError(f'{name}: otbr-agent REST never came up\n' + (self.dir / 'otbr.log').read_text())

    def uci_set(self, key, value):
        (self.dir / 'uci' / key).write_text(value)

    def ns(self, *cmd, check_rc=True, input=None):
        return sh('nsenter', '-t', str(self.holder.pid), '-n', '-m', '--', *cmd, check_rc=check_rc, input=input)

    def env(self):
        return ['env', f'PATH={SIM}:{WORK}/bin:/usr/sbin:/usr/bin:/sbin:/bin', f'UCI_STUB={self.dir}/uci',
                f'PULZR_PROBE_RUN={self.dir}/probe', f'PULZR_THREAD_RUN={self.dir}/run',
                f'PULZR_THREAD_NETWORK={self.dir}/network', f'PULZR_THREAD_OTCTL={SIM}/ot-ctl']

    def cli(self, *args, request=None, check_rc=True):
        r = self.ns(*self.env(), f'{SIM}/ucode', str(CLI), *args, check_rc=False,
                    input=json.dumps(request) if request is not None else '')
        outputs.append(r.stdout + r.stderr)
        if check_rc and r.returncode != 0:
            raise RuntimeError(f'{self.name}: pulzr-thread {" ".join(args)} failed ({r.returncode}): {r.stderr}')
        return r.stdout

    def otctl(self, *args):
        return self.ns(f'{SIM}/ot-ctl', '-I', 'wpan0', *args).stdout

    def status(self):
        return json.loads(self.cli('status'))

    def stop(self):
        for p in (self.agent, self.rcp):
            p.send_signal(signal.SIGTERM)
            try:
                p.wait(10)
            except subprocess.TimeoutExpired:
                p.kill()


outputs = []


# ── the device ──────────────────────────────────────────────────────────────

class Device:
    def __init__(self, node):
        self.p = spawn(f'{SIM}/ot-cli-ftd', str(node), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT, text=True, bufsize=1)
        self.lines = queue.Queue()
        self.log = open(WORK / f'device{node}.log', 'w')
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        for line in self.p.stdout:
            self.log.write(line)
            self.log.flush()
            self.lines.put(line.strip().lstrip('> ').strip())

    def cmd(self, c, until=('Done',), timeout=10):
        while not self.lines.empty():
            self.lines.get_nowait()
        self.p.stdin.write(c + '\n')
        self.p.stdin.flush()
        got, end = [], time.time() + timeout
        while time.time() < end:
            try:
                line = self.lines.get(timeout=0.5)
            except queue.Empty:
                continue
            got.append(line)
            if any(line.startswith(u) for u in until) or line.startswith('Error'):
                break
        return got

    def wait_for(self, c, pred, timeout):
        end = time.time() + timeout
        while time.time() < end:
            out = self.cmd(c)
            if pred(out):
                return out
            time.sleep(1)
        return None


def wait(pred, timeout, step=1.0):
    end = time.time() + timeout
    while time.time() < end:
        try:
            if pred():
                return True
        except Exception:
            pass
        time.sleep(step)
    return False


def main():
    shutil.rmtree(WORK, ignore_errors=True)
    (WORK / 'bin').mkdir(parents=True)
    # uci as pulzr-thread uses it, from one file per key.
    (WORK / 'bin' / 'uci').write_text('''#!/bin/sh
[ "$1" = -q ] && shift
case "$1" in
  get) cat "${UCI_STUB}/$2" 2>/dev/null || exit 1 ;;
  set) k="${2%%=*}"; printf '%s' "${2#*=}" > "${UCI_STUB}/${k}" ;;
  delete) rm -f "${UCI_STUB}/$2" ;;
  commit) ;;
esac
''')
    (WORK / 'bin' / 'uci').chmod(0o755)
    for n in EUI:
        sh('ip', 'netns', 'del', n, check_rc=False)

    br1 = BorderRouter('br1', 1)
    br2 = BorderRouter('br2', 2)

    try:
        scan = json.loads(br1.cli('scan'))
    except RuntimeError as e:
        scan = {'channels': [], 'recommended': None, 'error': str(e)}
    check('scan reports the 16 channels and a quiet one', len(scan['channels']) == 16 and scan['recommended'] in (15, 20, 25),
          json.dumps(scan))

    ds = make_dataset(scan['recommended'] or 15)
    key = parse(ds)
    netkey = next(raw for t, raw in key if t == 5)[2:].hex()
    network = '6f9619ff-8b86-4011-b42d-00c04fc964ff'

    s1 = json.loads(br1.cli('form', request={'dataset': ds.hex(), 'network': network}))
    check('form: the first border router leads the new network', s1['role'] == 'leader', json.dumps(s1))
    check('form: it runs the dataset the platform made', s1['dataset']['dataset_id'] == dataset_id(ds),
          f"{s1['dataset']['dataset_id']} != {dataset_id(ds)}")
    check('form: the network id is kept', (br1.dir / 'network').read_text().strip() == network)

    # What matter-bridge reads to give a Thread device the network when it
    # commissions it: otbr's own REST API on loopback, the active dataset as
    # hex TLVs. It must be this network, key and all.
    tlvs = br1.ns('curl', '-s', '-H', 'Accept: text/plain', 'http://127.0.0.1:8081/node/dataset/active').stdout.strip()
    try:
        handed = bytes.fromhex(tlvs)
    except ValueError:
        handed = b''
    check('matter: the commissioning dataset is the network the platform made',
          handed and dataset_id(handed) == dataset_id(ds) and netkey in tlvs.lower(), tlvs[:40])
    outputs.append('')

    # One gateway, one Thread network: a dataset for another is refused until leave.
    other = make_dataset(15)
    json.loads(br2.cli('form', request={'dataset': other.hex()}))
    r = br2.ns(*br2.env(), f'{SIM}/ucode', str(CLI), 'join', check_rc=False,
               input=json.dumps({'dataset': ds.hex(), 'network': network}))
    check('join: refused while the gateway is in another network',
          r.returncode != 0 and br2.status()['dataset']['dataset_id'] == dataset_id(other), r.stderr)
    br2.cli('leave')
    br2.otctl('routerselectionjitter', '1')
    s2 = json.loads(br2.cli('join', request={'dataset': ds.hex(), 'network': network}))
    check('join: the second border router attaches to the same partition',
          s2['role'] in ('child', 'router') and s2['partition_id'] == s1['partition_id'], json.dumps(s2))
    check('join: as a router', wait(lambda: br2.status()['role'] == 'router', 60), br2.status()['role'])

    # Commissioning: the device joins with its PSKd through a border router.
    permit = json.loads(br1.cli('permit', request={'eui64': '*', 'pskd': PSKD, 'seconds': 300}))
    check('permit: joining is open', permit['permitted'] == '*')
    dev = Device(3)
    dev.cmd('mode rn')
    dev.cmd('routereligible disable')
    dev.cmd('ifconfig up')
    joined = dev.cmd(f'joiner start {PSKD}', until=('Join success', 'Join failed'), timeout=90)
    check('the device joins by commissioning', any(l.startswith('Join success') for l in joined), joined)
    dev.cmd('thread start')
    check('the device attaches as a child',
          dev.wait_for('state', lambda o: 'child' in o, 60) is not None)
    br1.cli('permit-stop')

    parent_ext = next((l.split(':')[1].strip() for l in dev.cmd('parent') if l.startswith('Ext Addr')), None)
    by_ext = {br1.status()['ext_address']: br1, br2.status()['ext_address']: br2}
    parent = by_ext.get(parent_ext)
    check('the device\'s parent is a border router', parent is not None, f'{parent_ext} not in {list(by_ext)}')
    survivor = br2 if parent is br1 else br1
    dev_ext = next(l for l in dev.cmd('extaddr') if len(l) == 16)

    # The listener on the other border router, and its address on the mesh.
    target = next(l for l in survivor.otctl('ipaddr', 'mleid').splitlines() if ':' in l).strip()
    got = survivor.dir / 'received'
    listener = spawn('nsenter', '-t', str(survivor.holder.pid), '-n', '-m', '--', 'python3', '-u', '-c',
                     'import socket,sys\n'
                     's=socket.socket(socket.AF_INET6,socket.SOCK_DGRAM)\n'
                     's.bind(("::",5683))\n'
                     'f=open(sys.argv[1],"a")\n'
                     'while True:\n'
                     '  d,a=s.recvfrom(256); f.write(d.decode()+"\\n"); f.flush()\n', str(got))
    time.sleep(1)
    dev.cmd('udp open')
    stop_sending = threading.Event()

    def report():
        n = 0
        while not stop_sending.is_set():
            n += 1
            dev.cmd(f'udp send {target} 5683 r{n}', timeout=3)
            time.sleep(2)
    threading.Thread(target=report, daemon=True).start()

    count = lambda: len(got.read_text().split()) if got.exists() else 0
    check('the device reports to the other border router', wait(lambda: count() >= 3, 30), f'{count()} received')

    reporter = [b for b in (br1, br2) if len(json.loads(b.cli('topology', EUI[b.name]))['edges']) > 1]
    check('one border router reports the whole mesh', len(reporter) == 1, [b.name for b in reporter])
    if reporter:
        log('topology before:', reporter[0].cli('topology', EUI[reporter[0].name]).strip())

    # Its parent goes away, radio and all.
    log(f'stopping {parent.name}, the device\'s parent')
    parent.stop()
    before = count()
    t0 = time.time()
    ok = wait(lambda: count() >= before + 5, 180)
    check('the device keeps reporting with its parent border router stopped', ok,
          f'{count() - before} more in {time.time() - t0:.0f}s')
    log(f'reports resumed: {count() - before} in {time.time() - t0:.0f}s')
    new_parent = next((l.split(':')[1].strip() for l in dev.cmd('parent') if l.startswith('Ext Addr')), None)
    check('the device\'s parent is now the other border router',
          new_parent == survivor.status()['ext_address'], new_parent)

    def has_device():
        t = json.loads(survivor.cli('topology', EUI[survivor.name]))
        return any(e['from'] == f'thread:{dev_ext}' and e['to'] == f"thread:{survivor.status()['ext_address']}"
                   for e in t['edges'])
    check('topology from the survivor names the device under it', wait(has_device, 60, step=5))
    log('topology after:', survivor.cli('topology', EUI[survivor.name]).strip())
    st = json.loads(survivor.cli('state'))
    check('the survivor\'s protocol v1 state says up', st['network']['state'] == 'up' and st['online'], json.dumps(st))
    stop_sending.set()

    # No key anywhere but the export.
    exported = survivor.cli('dataset').strip()
    check('dataset exports the active dataset', exported and netkey in exported)
    outputs.pop()
    check('the network key is in no other output', not any(netkey in o for o in outputs))
    listen = survivor.ns('ss', '-ltnH').stdout
    rest = [line.split()[3].rsplit(':', 1)[0].strip('[]') for line in listen.splitlines()
            if line.split()[3].endswith(':8081')]
    check('the REST API listens on loopback only',
          rest and all(a in ('127.0.0.1', '::1', '::ffff:127.0.0.1') for a in rest), listen)

    s = json.loads(survivor.cli('leave'))
    check('leave erases the network', s.get('dataset') is None and not (survivor.dir / 'network').exists(), json.dumps(s))


def cleanup():
    for p in reversed(procs):
        try:
            p.kill()
        except Exception:
            pass
    for n in EUI:
        subprocess.run(['ip', 'netns', 'del', n], capture_output=True)


if __name__ == '__main__':
    try:
        main()
    except Exception as e:
        failures.append(f'crashed: {e}')
        log('crashed:', e)
    finally:
        cleanup()
        for f in sorted(WORK.glob('*/otbr.log')):
            log(f'--- {f} (last 40 lines)')
            print(''.join(f.read_text().splitlines(True)[-40:]))
    if failures:
        log(f'{len(failures)} failed: {failures}')
        sys.exit(1)
    log('all passed')
