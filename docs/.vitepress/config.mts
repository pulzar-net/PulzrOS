import { defineConfig } from 'vitepress';
import { boards, family, FAMILIES, REPO } from './boards.mjs';

const hardware = FAMILIES.map((f) => ({
  text: f,
  collapsed: true,
  items: boards()
    .filter((b) => family(b) === f)
    .map((b) => ({ text: b.name, link: `/hardware/${b.id}` })),
}));

export default defineConfig({
  title: 'PulzrOS',
  description: 'The open gateway OS for LoRaWAN, Bluetooth LE and IP devices, built on OpenWrt.',
  lang: 'en-US',
  // Served from GitHub Pages at pulzar-net.github.io/PulzrOS/.
  base: '/PulzrOS/',
  cleanUrls: true,
  srcExclude: ['**/node_modules/**'],
  // The mark is the console's own, so the two cannot drift apart.
  vite: { publicDir: '../console/public' },
  head: [['link', { rel: 'icon', type: 'image/svg+xml', href: '/PulzrOS/icon.svg' }]],

  themeConfig: {
    logo: '/icon.svg',
    siteTitle: 'PulzrOS',
    search: { provider: 'local' },
    outline: [2, 3],
    nav: [
      { text: 'Get started', link: '/getting-started' },
      { text: 'Hardware', link: '/hardware/' },
      { text: 'Build', link: '/building' },
      { text: 'Contribute', link: '/contributing' },
      { text: 'Releases', link: `${REPO}/releases` },
    ],
    sidebar: [
      {
        text: 'Getting started',
        items: [
          { text: 'Quick start', link: '/getting-started' },
          { text: 'Flashing', link: '/flashing' },
          { text: 'First boot and access', link: '/first-boot' },
        ],
      },
      {
        text: 'Hardware',
        items: [
          { text: 'Supported boards', link: '/hardware/' },
          ...hardware,
          { text: 'RAK7289CV2 power board', link: '/rak-power' },
        ],
      },
      {
        text: 'Console',
        items: [
          { text: 'Console guide', link: '/console' },
          { text: 'Terminal UI', link: '/tui' },
          { text: 'Setup access', link: '/access' },
        ],
      },
      {
        text: 'Networking',
        items: [
          { text: 'Overview', link: '/networking' },
          { text: 'Backhaul and management', link: '/backhaul' },
          { text: 'LAN ports', link: '/lan' },
          { text: 'Ports and VLANs', link: '/ports' },
          { text: 'WiFi radios and repeaters', link: '/radios' },
          { text: 'Speed tests', link: '/speedtest' },
        ],
      },
      {
        text: 'LoRaWAN and Bluetooth',
        items: [
          { text: 'Concentrators and GNSS', link: '/concentrators' },
          { text: 'Bluetooth', link: '/bluetooth' },
          { text: 'Plugged-in radios', link: '/usb-radios' },
          { text: 'Radio modules', link: '/radio-modules' },
        ],
      },
      {
        text: 'Fleet',
        items: [
          { text: 'One-touch provisioning', link: '/provisioning' },
          { text: 'Firmware updates and signing', link: '/firmware' },
          { text: 'Add-ons', link: '/addons' },
          { text: 'Thread', link: '/thread' },
          { text: 'Upgrading from ParkezeOS', link: '/legacy-migration' },
        ],
      },
      {
        text: 'Security',
        items: [
          { text: 'Security model', link: '/security' },
          { text: 'Authentication and SSH', link: '/auth' },
        ],
      },
      {
        text: 'Development',
        items: [
          { text: 'Building from source', link: '/building' },
          { text: 'Contributing', link: '/contributing' },
          { text: 'Adding a board', link: '/boards' },
          { text: 'Board features', link: '/features' },
          { text: 'Setup mode on a real gateway', link: '/setup-mode-validation' },
        ],
      },
    ],
    socialLinks: [{ icon: 'github', link: REPO }],
    editLink: {
      pattern: `${REPO}/edit/main/docs/:path`,
      text: 'Edit this page on GitHub',
    },
    footer: {
      message: 'Released under the Apache-2.0 license.',
      copyright: 'Copyright Pulzar LLC and contributors',
    },
  },
});
