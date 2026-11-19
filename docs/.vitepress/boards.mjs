// The Hardware pages, from the board files themselves.
//
// scripts/board-facts.sh sources each boards/<id>/board.conf the way build.sh
// does and prints what it found. Everything a Hardware page says comes from
// there, so a board's page cannot disagree with the image built for it.

import { execFileSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const REPO = 'https://github.com/pulzar-net/PulzrOS';
const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');

let cache;
export function boards() {
  cache ??= JSON.parse(
    execFileSync('bash', [path.join(ROOT, 'scripts/board-facts.sh')], { encoding: 'utf8' }),
  );
  return cache;
}

export function family(b) {
  if (b.id.startsWith('rpi')) return 'Raspberry Pi';
  if (b.id.startsWith('rak')) return 'RAKwireless';
  return 'Other';
}

export const FAMILIES = ['Raspberry Pi', 'RAKwireless', 'Other'];

export const FEATURES = {
  lorawan: 'LoRaWAN',
  gnss: 'GNSS',
  bluetooth: 'Bluetooth LE',
  cellular: 'Cellular',
  wifi: 'WiFi',
  lan: 'LAN ports',
  dns: 'DNS',
  failover: 'Uplink failover',
  speedtest: 'Speed test',
};

export function statusText(b) {
  return b.status === 'supported' ? 'Image built by CI' : 'No image yet: needs device support';
}

export function radio(b) {
  if (!b.features.includes('lorawan')) return 'None';
  if (b.slots.length === 1 && b.slots[0] === 'auto') return 'Probed: SPI, USB or UART';
  const n = b.slots.length;
  const bus = [...new Set(b.slots.map((s) => s.split(':')[0].toUpperCase()))].join(', ');
  return `${n * 8} channels, ${n === 1 ? 'one' : n} concentrator${n === 1 ? '' : 's'} on ${bus}`;
}

function slot(s) {
  if (s === 'auto') return 'probed on every bus, editable in the console';
  const [bus, dev, reset, power] = s.split(':');
  const parts = [`${bus.toUpperCase()} \`${dev}\``];
  if (reset && reset !== '-') parts.push(`reset ${/^\d+$/.test(reset) ? `GPIO ${reset}` : `\`${reset}\``}`);
  if (power) parts.push(`power GPIO ${power}`);
  return parts.join(', ');
}

// board.conf's header is plain text written for a terminal. Paragraphs become
// paragraphs, indented runs stay preformatted, and nothing in it is read as
// markup: VitePress compiles a page as a Vue template, so a stray `<bus>`
// would otherwise break the build.
function escapeProse(text) {
  return text
    .split(/(`[^`]*`)/)
    .map((seg, i) => (i % 2 ? seg : seg.replace(/[\\*_[\]<>]/g, (c) => (c === '<' ? '&lt;' : c === '>' ? '&gt;' : `\\${c}`))))
    .join('');
}

function notes(header) {
  const out = [];
  for (const block of header.split(/\n\s*\n/)) {
    const lines = block.split('\n').filter((l) => l.trim() !== '');
    if (!lines.length) continue;
    const rule = lines[0].match(/^─+\s*(.+?)\s*─*$/);
    if (rule && lines.length === 1) {
      out.push(`### ${escapeProse(rule[1])}`);
    } else if (lines.every((l) => /^\s/.test(l))) {
      const indent = Math.min(...lines.map((l) => l.match(/^\s*/)[0].length));
      out.push('```text\n' + lines.map((l) => l.slice(indent)).join('\n') + '\n```');
    } else if (/^\s*[*-] /.test(lines[0])) {
      out.push(lines.map((l) => (/^\s*[*-] /.test(l) ? `- ${escapeProse(l.replace(/^\s*[*-] /, ''))}` : `  ${escapeProse(l.trim())}`)).join('\n'));
    } else {
      out.push(escapeProse(lines.map((l) => l.trim()).join(' ')));
    }
  }
  return out.join('\n\n');
}

const yes = (v, text) => (v ? text : 'None');

export function boardPage(b) {
  const [summary, ...rest] = b.header.split('\n');
  const rows = [
    ['Board ID', `\`${b.id}\``],
    ['Image', statusText(b)],
    ['Install', b.install === 'sdcard' ? '[SD card](/flashing)' : 'From the running system or the bootloader'],
    ['OpenWrt', `${b.openwrt}, \`${b.target}/${b.subtarget}\`, \`${b.arch}\``],
    ['Features', b.features.map((f) => FEATURES[f] ?? f).join(', ')],
    ['LoRa radio', radio(b)],
  ];
  if (b.features.includes('lorawan')) {
    if (b.part) rows.push(['Concentrator part', `\`${b.part}\`${b.model ? `, \`${b.model}\`` : ''}`]);
    b.slots.forEach((s, i) => rows.push([`Slot ${i}`, slot(s)]));
  }
  rows.push(
    ['GNSS', { auto: 'Probed', fixed: 'Built in', none: 'None' }[b.gps] ?? b.gps],
    ['Bluetooth', yes(b.bluetooth, `On the ${b.bluetooth.toUpperCase()}`)],
    ['Local screen', yes(b.display, b.display.toUpperCase())],
    ['USB device port', yes(b.usbGadget, `\`${b.usbGadget}\` (console over USB)`)],
    ['LAN ports', yes(b.lanPorts.length, b.lanPorts.map((p) => `\`${p}\``).join(', '))],
    ['Built-in add-ons', yes(b.builtinAddons.length, b.builtinAddons.map((a) => `\`${a}\``).join(', '))],
  );

  const md = [
    `# ${b.name}`,
    '',
    `<Badge type="${b.status === 'supported' ? 'tip' : 'warning'}" text="${statusText(b)}" />`,
    '',
    escapeProse(summary),
    '',
    '| | |',
    '|---|---|',
    ...rows.map(([k, v]) => `| ${k} | ${v} |`),
    '',
  ];

  if (b.leds.length) {
    md.push('## Panel lights', '', '| Label | Colour | Role | sysfs |', '|---|---|---|---|');
    for (const l of b.leds) md.push(`| ${l.label} | ${l.colour} | ${l.role} | \`${l.sysfs}\` |`);
    md.push('');
  }

  md.push('## Install', '');
  if (b.status !== 'supported') {
    md.push(
      'No image is built for this board yet. Its OpenWrt device support is in the repository and has to build and boot on a unit first.',
      '',
    );
  } else if (b.install === 'sdcard') {
    md.push(
      'Write the image to an SD card with any writer, or:',
      '',
      '```bash',
      `./flash.sh --download ${b.id}`,
      '```',
      '',
      'See [Flashing](/flashing).',
      '',
    );
  } else {
    md.push(
      'This board boots from soldered flash. A unit already running PulzrOS upgrades from its console or with `sysupgrade` ([Firmware updates](/firmware)).',
      '',
    );
  }
  if (b.readme) {
    md.push(`The first install, recovery and the hardware record: [\`${b.readme}\`](${REPO}/blob/main/${b.readme}).`, '');
  }

  const body = notes(rest.join('\n').replace(/^\s*\n/, ''));
  if (body) md.push('## Notes from board.conf', '', '::: v-pre', body, ':::', '');

  md.push(`Source: [\`boards/${b.id}/board.conf\`](${REPO}/blob/main/boards/${b.id}/board.conf)`, '');
  return md.join('\n');
}
