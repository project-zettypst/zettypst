// Typst owns knowledge semantics, routes and card HTML. This integration runs
// the bundle export, typesets its math, serves each document inside the site
// shell, and publishes the remaining files as static assets.
//
// The site understands only these marks in Typst's output:
//   section[data-zk-node=id]              a card (kickstart export-html)
//   [data-zk-source][data-zk-target]      a note link, an edge with both endpoints
//   [data-zk-view~=name]                  what a card shows elsewhere: preview,
//                                         expand, about (element or <template>)
//   [data-zk-expand=id]                   a collapsed tree to expand in place
//   zettypst.json                         published notes: id, route, title
import { spawn } from 'node:child_process';
import { createReadStream, existsSync, realpathSync, statSync } from 'node:fs';
import { cp, mkdir, readdir, readFile, rename, rm, writeFile } from 'node:fs/promises';
import { extname, join, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createTypesetter, fontDirectory, licenseFile } from './math/typeset.mjs';
import { materializeDirectory } from './transclusion.mjs';

// URL namespace of the files this integration owns; Typst owns every other path.
export const OWN = '_zettypst';
const MATH_FONTS = 'mathjax';
const theme = fileURLToPath(new URL('../theme/', import.meta.url));

const types = {
  '.json': 'application/json', '.css': 'text/css', '.js': 'text/javascript',
  '.svg': 'image/svg+xml', '.png': 'image/png', '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg', '.gif': 'image/gif', '.webp': 'image/webp',
  '.woff2': 'font/woff2', '.pdf': 'application/pdf', '.txt': 'text/plain',
};

function run(command, args, cwd) {
  return new Promise((done, fail) => {
    const child = spawn(command, args, { cwd, stdio: ['ignore', 'inherit', 'pipe'] });
    let stderr = '';
    child.stderr.on('data', chunk => { stderr += chunk; process.stderr.write(chunk); });
    child.on('error', fail);
    child.on('close', status => done({ status, stderr }));
  });
}

async function files(dir, prefix = '') {
  const entries = await readdir(dir, { withFileTypes: true });
  const nested = await Promise.all(entries.map(entry => entry.isDirectory()
    ? files(join(dir, entry.name), join(prefix, entry.name))
    : [join(prefix, entry.name)]));
  return nested.flat();
}

async function write(path, data) {
  await mkdir(resolve(path, '..'), { recursive: true });
  await writeFile(path, data);
}

/**
 * @param {object} [options]
 * @param {string} [options.entry] Typst bundle entry, relative to `root`.
 * @param {string} [options.root] Typst project root; defaults to Astro's root.
 * @param {string} [options.typst] Typst executable.
 * @param {Record<string, string>} [options.inputs] Extra `sys.inputs`.
 * @param {number} [options.batchSize] Compile this many routes at a time. The entry
 * must honor the `zettypst.documents` input (supported by the kickstart template).
 */
export default function zettypst(options = {}) {
  const { entry = 'site.typ', typst = process.env.TYPST || 'typst', inputs = {}, batchSize } = options;
  if (batchSize !== undefined && (!Number.isInteger(batchSize) || batchSize < 1)) {
    throw new Error('batchSize must be a positive integer');
  }
  const math = createTypesetter({ fontURL: MATH_FONTS });
  let root, pages, owned;
  // Every file the last compilation read, by real path: notes, manifests,
  // configuration and packages alike, including linked development packages.
  let dependencies = new Set();
  const real = file => { try { return realpathSync(resolve(root, file)); } catch { return null; } };

  async function readDependencies(file) {
    try {
      const { inputs } = JSON.parse(await readFile(file, 'utf8'));
      return new Set(inputs.map(real).filter(Boolean));
    } catch { return null; }
  }

  // Compile and typeset into a fresh directory, then swap, so readers never
  // see a half-written bundle. Strict builds fail on anything lossy.
  async function build(strict) {
    const next = pages + '.next';
    await rm(next, { recursive: true, force: true });
    await mkdir(next, { recursive: true });
    const deps = pages + '.deps.json';
    const args = [
      'compile', '--features', 'bundle,html', '--format', 'bundle', '--root', root,
      '--deps', deps,
      ...Object.entries(inputs).flatMap(([key, value]) => ['--input', `${key}=${value}`]),
      resolve(root, entry), next,
    ];
    try {
      const allReads = new Set();
      const fingerprints = new Map();
      const compile = async (target, routes) => {
        const invocation = [...args.slice(0, -1),
          ...(routes === undefined ? [] : ['--input', 'zettypst.documents=' + JSON.stringify(routes)]),
          target];
        const { status, stderr } = await run(typst, invocation, root);
        // Keep reads from every batch, including failed evaluations.
        const read = await readDependencies(deps);
        if (read) for (const file of read) {
          allReads.add(file);
          if (batchSize !== undefined) {
            const stat = statSync(file);
            const fingerprint = stat.mtimeMs + ':' + stat.size;
            if (fingerprints.has(file) && fingerprints.get(file) !== fingerprint) {
              throw new Error('Source changed during batched build: ' + file);
            }
            fingerprints.set(file, fingerprint);
          }
        }
        dependencies = new Set([...dependencies, ...allReads]);
        if (status !== 0) throw new Error('Typst compilation failed');
        if (strict && /warning:.*(?:ignored|unsupported)|did not converge/i.test(stderr)) {
          throw new Error('Typst dropped content in HTML export');
        }
      };
      await compile(next, batchSize === undefined ? undefined : []);
      if (batchSize !== undefined) {
        const index = JSON.parse(await readFile(join(next, 'zettypst.json'), 'utf8'));
        const routes = [...new Set(index.map(note => note.route))];
        // The index pass must not have rendered node pages: fail on an old entry
        // rather than silently recompiling the entire graph for every batch.
        for (const route of routes) {
          if (existsSync(join(next, route))) throw new Error('Entry does not honor zettypst.documents');
        }
        const part = pages + '.batch';
        try {
          for (let start = 0; start < routes.length; start += batchSize) {
            const batch = routes.slice(start, start + batchSize);
            await rm(part, { recursive: true, force: true });
            await mkdir(part, { recursive: true });
            await compile(part, batch);
            const currentIndex = JSON.parse(await readFile(join(part, 'zettypst.json'), 'utf8'));
            if (JSON.stringify(currentIndex) !== JSON.stringify(index)) {
              throw new Error('Publication index changed during batched build');
            }
            for (const route of batch) {
              if (!existsSync(join(part, route))) throw new Error('Missing batch document: ' + route);
            }
            for (const file of await files(part)) {
              const target = join(next, file);
              if (existsSync(target)) {
                if (!(await readFile(target)).equals(await readFile(join(part, file)))) {
                  throw new Error('Conflicting batch artifact: ' + file);
                }
              } else {
                await mkdir(resolve(target, '..'), { recursive: true });
                await cp(join(part, file), target);
              }
            }
          }
        } finally {
          await rm(part, { recursive: true, force: true });
        }
      }
      dependencies = allReads;
      if ((await files(next)).some(file => file.split(sep)[0] === OWN)) {
        throw new Error(`Routes must not use the reserved ${OWN}/ namespace`);
      }
      for (const file of await files(next)) {
        if (extname(file) !== '.html') continue;
        const path = join(next, file);
        await writeFile(path, await math.typeset(await readFile(path, 'utf8')));
      }
      await materializeDirectory(next);
    } catch (error) {
      await rm(next, { recursive: true, force: true });
      if (strict) throw error;
      console.error(error);
      return false;
    }
    await rm(pages, { recursive: true, force: true });
    await rename(next, pages);
    await publishOwned();
    return true;
  }

  // Shared math stylesheet with its fonts, and the licenses of vendored assets.
  async function publishOwned() {
    const { css, fonts } = await math.stylesheet();
    await write(join(owned, 'math.css'), css);
    for (const font of fonts) {
      await cp(join(fontDirectory, font), join(owned, MATH_FONTS, font));
    }
    await cp(join(theme, 'LICENSES'), join(owned, 'LICENSES'), { recursive: true });
    await cp(join(theme, 'UPSTREAM'), join(owned, 'LICENSES', 'forester-base-theme.UPSTREAM'));
    await cp(licenseFile, join(owned, 'LICENSES', 'MathJax-Apache-2.0.txt'));
  }

  function serve(server) {
    server.middlewares.use((request, response, next) => {
      const base = server.config.base;
      const url = decodeURIComponent((request.url ?? '').split(/[?#]/)[0]);
      if (!url.startsWith(base)) return next();
      const path = url.slice(base.length);
      const [dir, file] = path.split('/')[0] === OWN
        ? [owned, path.slice(OWN.length + 1)]
        : [pages, path];
      const full = join(dir, file);
      if (!full.startsWith(dir + sep) || extname(full) === '.html'
          || !existsSync(full) || !statSync(full).isFile()) return next();
      response.setHeader('Content-Type', types[extname(full)] ?? 'application/octet-stream');
      createReadStream(full).pipe(response);
    });
  }

  return {
    name: 'zettypst-site',
    hooks: {
      'astro:config:setup': async ({ config, command, injectRoute, updateConfig }) => {
        root = resolve(fileURLToPath(config.root), options.root ?? '.');
        pages = join(fileURLToPath(config.cacheDir), 'zettypst', 'pages');
        owned = join(fileURLToPath(config.cacheDir), 'zettypst', OWN);
        await build(command === 'build');
        injectRoute({
          pattern: '/[...path]',
          entrypoint: new URL('./page.astro', import.meta.url),
          prerender: true,
        });
        updateConfig({
          vite: {
            define: { 'import.meta.env.ZETTYPST_STAGE': JSON.stringify(pages) },
            plugins: [{ name: 'zettypst-assets', configureServer: serve }],
            // The shell's theme may live outside the project (linked package).
            server: { fs: { allow: [root, fileURLToPath(new URL('..', import.meta.url))] } },
          },
        });
      },
      'astro:server:setup': ({ server, logger }) => {
        // Rebuild when a file the compilation read changes; Typst reports them.
        const watch = () => server.watcher.add([...dependencies]);
        watch();
        let running = null;
        let again = false;
        const rebuild = () => {
          if (running) { again = true; return; }
          running = build(false).then(ok => {
            logger.info(ok ? 'Rebuilt ZetTypst site' : 'Keeping the previous ZetTypst site');
            if (ok) server.ws.send({ type: 'full-reload' });
          }).finally(() => {
            watch();
            running = null;
            if (again) { again = false; rebuild(); }
          });
        };
        for (const event of ['add', 'change', 'unlink']) {
          // A deleted file has no real path left; match it as named.
          server.watcher.on(event, file => { if (dependencies.has(real(file) ?? resolve(file))) rebuild(); });
        }
      },
      'astro:build:done': async ({ dir }) => {
        const out = fileURLToPath(dir);
        for (const file of await files(pages)) {
          if (extname(file) !== '.html') await cp(join(pages, file), join(out, file));
        }
        await cp(owned, join(out, OWN), { recursive: true });
      },
    },
  };
}
