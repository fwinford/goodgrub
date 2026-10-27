// build-client.mjs
// Build script for client-side TypeScript

import * as esbuild from 'esbuild';
import { existsSync, mkdirSync } from 'fs';

const outdir = './public/js';

// Ensure output directory exists
if (!existsSync(outdir)) {
  mkdirSync(outdir, { recursive: true });
}

const isDev = process.env.NODE_ENV !== 'production';

// The files in public/js are committed, so they look editable both in the repo
// and in the browser's Sources panel. This banner is the only notice at the
// point of use that an edit there is discarded by the next build.
const GENERATED_BANNER = [
  '// GENERATED FILE — do not edit.',
  '// Built from src/client/*.ts by build-client.mjs (npm run build:client).',
  '// Edit the TypeScript source; edits here are overwritten by the next build.',
].join('\n');

// Build client scripts
await esbuild.build({
  entryPoints: [
    'src/client/home.ts',
    'src/client/new-request.ts',
    'src/client/fulfill.ts'
  ],
  bundle: true,
  outdir,
  format: 'esm',
  target: 'es2022',
  banner: { js: GENERATED_BANNER },
  sourcemap: isDev, // Only generate sourcemaps in development
  minify: !isDev,
});

console.log(`Client scripts built successfully${isDev ? ' (with sourcemaps)' : ''}`);
