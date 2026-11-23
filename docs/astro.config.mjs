// The PulzrOS docs: Starlight with the shared Pulzr theme
// (github.com/pulzar-net/docs-theme). Pages are in src/content/docs; the
// Hardware pages come from boards/*/board.conf (src/boards.mjs). Built and
// published by .github/workflows/docs.yml.
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';
import { pulzarPlugins } from '@pulzr/docs-theme';
import { FAMILIES, boards, family } from './src/boards.mjs';

const hardware = FAMILIES.map((f) => ({
	label: f,
	collapsed: true,
	items: boards()
		.filter((b) => family(b) === f)
		.map((b) => ({ label: b.name, link: `/hardware/${b.id}` })),
}));

export default defineConfig({
	site: 'https://oss.pulzr.net',
	base: '/PulzrOS',
	// Pages are page.html; GitHub Pages also serves them at the clean URLs
	// the earlier VitePress site had (/PulzrOS/flashing).
	build: { format: 'file' },
	redirects: { '/hardware/index': '/PulzrOS/hardware.html' },
	integrations: [
		starlight({
			title: 'PulzrOS',
			description: 'The open gateway OS for LoRaWAN, Bluetooth LE and IP devices, built on OpenWrt.',
			plugins: pulzarPlugins({ project: 'PulzrOS', license: 'Apache-2.0' }),
			sidebar: [
				{
					label: 'Getting started',
					items: [
						{ label: 'Quick start', slug: 'getting-started' },
						{ label: 'Flashing', slug: 'flashing' },
						{ label: 'First boot and access', slug: 'first-boot' },
					],
				},
				{
					label: 'Hardware',
					items: [
						{ label: 'Supported boards', slug: 'hardware' },
						...hardware,
						{ label: 'RAK7289CV2 power board', slug: 'rak-power' },
					],
				},
				{
					label: 'Console',
					items: [
						{ label: 'Console guide', slug: 'console' },
						{ label: 'Terminal UI', slug: 'tui' },
						{ label: 'Setup access', slug: 'access' },
					],
				},
				{
					label: 'Networking',
					items: [
						{ label: 'Overview', slug: 'networking' },
						{ label: 'Backhaul and management', slug: 'backhaul' },
						{ label: 'LAN ports', slug: 'lan' },
						{ label: 'Ports and VLANs', slug: 'ports' },
						{ label: 'WiFi radios and repeaters', slug: 'radios' },
						{ label: 'Speed tests', slug: 'speedtest' },
					],
				},
				{
					label: 'LoRaWAN and Bluetooth',
					items: [
						{ label: 'Concentrators and GNSS', slug: 'concentrators' },
						{ label: 'Bluetooth', slug: 'bluetooth' },
						{ label: 'Plugged-in radios', slug: 'usb-radios' },
						{ label: 'Radio modules', slug: 'radio-modules' },
					],
				},
				{
					label: 'Fleet',
					items: [
						{ label: 'One-touch provisioning', slug: 'provisioning' },
						{ label: 'Firmware updates and signing', slug: 'firmware' },
						{ label: 'Logging', slug: 'logging' },
						{ label: 'Add-ons', slug: 'addons' },
						{ label: 'Thread', slug: 'thread' },
						{ label: 'Upgrading from ParkezeOS', slug: 'legacy-migration' },
					],
				},
				{
					label: 'Security',
					items: [
						{ label: 'Security model', slug: 'security' },
						{ label: 'Authentication and SSH', slug: 'auth' },
					],
				},
				{
					label: 'Development',
					items: [
						{ label: 'Building from source', slug: 'building' },
						{ label: 'Contributing', slug: 'contributing' },
						{ label: 'Adding a board', slug: 'boards' },
						{ label: 'Board features', slug: 'features' },
						{ label: 'Setup mode on a real gateway', slug: 'setup-mode-validation' },
					],
				},
				{ label: 'Releases', link: 'https://github.com/pulzar-net/PulzrOS/releases' },
			],
		}),
	],
});
