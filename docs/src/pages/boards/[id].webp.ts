// Each board's photo, beside index.json, at the URL its `photo.src` gives.
import type { APIRoute, GetStaticPaths } from 'astro';
import { readFileSync } from 'node:fs';
import { photoFiles } from '../../boards.mjs';

export const getStaticPaths: GetStaticPaths = () =>
	photoFiles().map(({ id, file }) => ({ params: { id }, props: { file } }));

export const GET: APIRoute = ({ props }) => new Response(readFileSync(props.file as string), {
	headers: { 'Content-Type': 'image/webp' },
});
