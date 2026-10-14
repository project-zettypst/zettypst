# zettypst-site

An Astro integration publishing a ZetTypst project as a static site, with Typst-declared cards and stacked reading.

```js
import { defineConfig } from 'astro/config';
import zettypst from 'zettypst-site';

export default defineConfig({ integrations: [zettypst({ entry: 'site.typ' })] });
```

[MIT](LICENSE).
