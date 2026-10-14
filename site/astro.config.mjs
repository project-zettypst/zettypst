import { fileURLToPath } from 'node:url';
import { defineConfig } from 'astro/config';
import zettypst from './src/integration.mjs';

export default defineConfig({
  integrations: [zettypst({
    root: fileURLToPath(new URL('../typst/kickstart/template/', import.meta.url)),
    entry: 'site.typ',
  })],
});
