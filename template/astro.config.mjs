import { defineConfig } from 'astro/config';
import zettypst from 'zettypst-site';

export default defineConfig({
  site: process.env.SITE_URL,
  base: process.env.BASE_PATH || '/',
  integrations: [zettypst()],
});
