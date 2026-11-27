// The Hardware pages, from the board files themselves.
//
// scripts/board-facts.sh sources each board.conf (boards/<maker>/<folder>/) the way build.sh
// does and prints what it found. Everything a Hardware page says comes from
// there, so a board's page cannot disagree with the image built for it. Used
// by the sidebar (astro.config.mjs), the board table (hardware.mdx) and each
// board's page (src/pages/hardware/[board].astro).

import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';

export const REPO = 'https://github.com/pulzar-net/PulzrOS';
export const BASE = '/PulzrOS';
// Astro runs in docs/ (and bundles this module elsewhere, so its own URL
// is no guide): the repository is the parent of the working directory.
const ROOT = path.resolve(process.cwd(), '..');

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

export const built = (b) => b.status === 'supported';

export function statusText(b) {
	return built(b) ? 'Image built by CI' : 'No image yet: needs device support';
}

export const features = (b) => b.features.map((f) => FEATURES[f] ?? f).join(', ');

export function radio(b) {
	if (!b.features.includes('lorawan')) return 'None';
	if (b.slots.length === 1 && b.slots[0] === 'auto') return 'Probed: SPI, USB or UART';
	const n = b.slots.length;
	const bus = [...new Set(b.slots.map((s) => s.split(':')[0].toUpperCase()))].join(', ');
	return `${n * 8} channels, ${n === 1 ? 'one' : n} concentrator${n === 1 ? '' : 's'} on ${bus}`;
}

// Text from board.conf is plain text written for a terminal: it is escaped,
// and only `backticks` become code.
const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]);
export const code = (s) => `<code>${esc(s)}</code>`;
export function inline(text) {
	return text
		.split(/(`[^`]*`)/)
		.map((seg, i) => (i % 2 ? code(seg.slice(1, -1)) : esc(seg)))
		.join('');
}

function slot(s) {
	if (s === 'auto') return 'probed on every bus, editable in the console';
	const [bus, dev, reset, power] = s.split(':');
	const parts = [`${bus.toUpperCase()} ${code(dev)}`];
	if (reset && reset !== '-') parts.push(`reset ${/^\d+$/.test(reset) ? `GPIO ${reset}` : code(reset)}`);
	if (power) parts.push(`power GPIO ${power}`);
	return parts.join(', ');
}

const yes = (v, html) => (v ? html : 'None');

// The facts table on a board's page: [label, HTML] rows.
export function facts(b) {
	const rows = [
		['Board ID', code(b.id)],
		['Image', statusText(b)],
		['Install', b.install === 'sdcard' ? `<a href="${BASE}/flashing.html">SD card</a>` : 'From the running system or the bootloader'],
		['OpenWrt', `${esc(b.openwrt)}, ${code(`${b.target}/${b.subtarget}`)}, ${code(b.arch)}`],
		['Features', esc(features(b))],
		['LoRa radio', esc(radio(b))],
	];
	if (b.features.includes('lorawan')) {
		if (b.part) rows.push(['Concentrator part', `${code(b.part)}${b.model ? `, ${code(b.model)}` : ''}`]);
		b.slots.forEach((s, i) => rows.push([`Slot ${i}`, slot(s)]));
	}
	rows.push(
		['GNSS', esc({ auto: 'Probed', fixed: 'Built in', none: 'None' }[b.gps] ?? b.gps)],
		['Bluetooth', yes(b.bluetooth, `On the ${esc(b.bluetooth.toUpperCase())}`)],
		['Local screen', yes(b.display, esc(b.display.toUpperCase()))],
		['USB device port', yes(b.usbGadget, `${code(b.usbGadget)} (console over USB)`)],
		['LAN ports', yes(b.lanPorts.length, b.lanPorts.map(code).join(', '))],
		['Built-in add-ons', yes(b.builtinAddons.length, b.builtinAddons.map(code).join(', '))],
	);
	return rows;
}

// board.conf's header after its first line, as blocks: a ── rule line is a
// heading, an indented run stays preformatted, `-`/`*` lines are a list, and
// the rest are paragraphs.
export function notes(header) {
	const out = [];
	for (const block of header.split(/\n\s*\n/)) {
		const lines = block.split('\n').filter((l) => l.trim() !== '');
		if (!lines.length) continue;
		const rule = lines[0].match(/^─+\s*(.+?)\s*─*$/);
		if (rule && lines.length === 1) {
			out.push({ type: 'h3', html: inline(rule[1]) });
		} else if (lines.every((l) => /^\s/.test(l))) {
			const indent = Math.min(...lines.map((l) => l.match(/^\s*/)[0].length));
			out.push({ type: 'pre', text: lines.map((l) => l.slice(indent)).join('\n') });
		} else if (/^\s*[*-] /.test(lines[0])) {
			const items = [];
			for (const l of lines) {
				if (/^\s*[*-] /.test(l)) items.push(l.replace(/^\s*[*-] /, ''));
				else items[items.length - 1] += ` ${l.trim()}`;
			}
			out.push({ type: 'ul', items: items.map(inline) });
		} else {
			out.push({ type: 'p', html: inline(lines.map((l) => l.trim()).join(' ')) });
		}
	}
	return out;
}

// How the consoles draw each board: its hardware.json, with the photo's file
// turned into its URL on this site (src/pages/boards/).
function readHardware(b) {
	const file = path.join(ROOT, b.dir, 'hardware.json');
	if (!existsSync(file)) return null;
	const h = JSON.parse(readFileSync(file, 'utf8'));
	if (h.photo) {
		const { file: _, ...credit } = h.photo;
		h.photo = { src: `https://oss.pulzr.net${BASE}/boards/${b.id}.webp`, ...credit };
	}
	return h;
}

export function hardware() {
	return Object.fromEntries(boards().map((b) => [b.id, readHardware(b)]).filter(([, h]) => h));
}

export function hardwareOf(b) {
	return readHardware(b);
}

export function photoFiles() {
	return boards()
		.map((b) => ({ id: b.id, file: path.join(ROOT, b.dir, 'photo.webp') }))
		.filter(({ file }) => existsSync(file));
}
