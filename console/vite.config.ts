import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import { fileURLToPath, URL } from 'node:url';

/**
 * The console is served by uhttpd off a read-only squashfs on the gateway.
 * There is no Node and no server-side rendering on the device — this builds to
 * plain static files that uhttpd hands out, and everything dynamic happens
 * against the ucode API under /api.
 */
export default defineConfig({
  plugins: [react()],
  resolve: {
    alias: { '@': fileURLToPath(new URL('./src', import.meta.url)) },
  },
  build: {
    // build.sh points this straight at the package payload.
    outDir: process.env.PULZR_CONSOLE_OUT || 'dist',
    emptyOutDir: true,
    // No sourcemaps in the image: they are larger than the code and there is
    // no debugger attached to a gateway on a pole.
    sourcemap: false,
    // Everything in one pair of files. HTTP/1.1 from uhttpd with a handful of
    // concurrent requests makes many small chunks slower than one bundle, and
    // the whole app is well under the size where splitting starts to pay.
    rollupOptions: {
      output: {
        manualChunks: undefined,
        entryFileNames: 'assets/[name]-[hash].js',
        chunkFileNames: 'assets/[name]-[hash].js',
        assetFileNames: 'assets/[name]-[hash][extname]',
      },
    },
    // A gateway console that has grown past this has almost certainly grown a
    // dependency it does not need. Fail the build rather than quietly shipping
    // it to a flash-constrained board.
    chunkSizeWarningLimit: 600,
  },
  server: {
    // `npm run dev` against a real gateway on the bench.
    proxy: {
      '/api': {
        target: process.env.PULZR_GATEWAY || 'https://192.168.61.1',
        changeOrigin: true,
        secure: false,
      },
    },
  },
});
