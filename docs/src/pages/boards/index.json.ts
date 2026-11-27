// Every board's hardware description (boards/<maker>/<folder>/hardware.json),
// keyed by board id, for Pulzr Cloud's console: it draws a PulzrOS gateway
// from here with @pulzr/ui. A photo's `src` is its URL on this site.
import type { APIRoute } from 'astro';
import { hardware } from '../../boards.mjs';

export const GET: APIRoute = () => new Response(JSON.stringify(hardware(), null, 2), {
	headers: { 'Content-Type': 'application/json' },
});
