// Compile Typst math with the site's HTML rules, exactly as cards are
// compiled, and return each <math> element Typst emits.
import { execFileSync, spawnSync } from 'node:child_process';
import { cpSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parse } from 'node-html-parser';
import { serializeFootnotes } from '../src/footnotes.mjs';
import { isolatePage } from '../src/fragments.mjs';
import { serializeMeta } from '../src/metadata.mjs';

const rules = fileURLToPath(new URL('../../typst/site/lib.typ', import.meta.url));

/** Absolute paths of the Typst sources under test, for `#import`. */
export const sources = {
  site: rules,
  kickstart: fileURLToPath(new URL('../../typst/kickstart/lib.typ', import.meta.url)),
};

/** Compile a Typst document to HTML and return the parsed page. */
export function typstHTML(source) {
  const dir = mkdtempSync(join(tmpdir(), 'zettypst-test-'));
  try {
    const main = join(dir, 'main.typ');
    writeFileSync(main, source);
    execFileSync(process.env.TYPST || 'typst', [
      'compile', '--features', 'html', '--format', 'html', '--root', '/', main, join(dir, 'out.html'),
    ], { stdio: ['ignore', 'ignore', 'pipe'], timeout: 10000 });
    return parse(readFileSync(join(dir, 'out.html'), 'utf8'));
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

/** Compile a fixture project's bundle; returns each HTML page, parsed, by path. */
export function typstBundle(fixture, entry = 'site.typ', sources = {}) {
  const fixtureRoot = fileURLToPath(new URL(`fixtures/${fixture}/`, import.meta.url));
  const work = mkdtempSync(join(tmpdir(), 'zettypst-bundle-'));
  const root = join(work, 'project');
  const out = join(work, 'out');
  try {
    const packages = join(work, 'packages');
    const packageRoot = join(packages, 'preview', 'zettyp', '0.1.0');
    mkdirSync(packageRoot, { recursive: true });
    cpSync(fileURLToPath(new URL('../../typst/', import.meta.url)), packageRoot, { recursive: true });
    cpSync(fixtureRoot, root, { recursive: true, dereference: true, filter: () => true });
    const modules = fileURLToPath(new URL('../../typst/kickstart/template/.zettypst/', import.meta.url));
    for (const file of readdirSync(modules)) {
      if (file.endsWith('.typ')) cpSync(join(modules, file), join(root, '.zettypst', file));
    }
    for (const [path, content] of Object.entries(sources)) {
      writeFileSync(join(root, path), content);
    }
    const compiled = spawnSync(process.env.TYPST || 'typst', [
      'compile', '--package-path', packages, '--features', 'bundle,html', '--format', 'bundle', '--root', root, join(root, entry), out,
    ], { encoding: 'utf8', timeout: 10000 });
    if (compiled.error) throw compiled.error;
    if (compiled.status !== 0 || /did not converge/i.test(compiled.stderr)) {
      throw new Error(`Typst bundle failed (status ${compiled.status}):\n${compiled.stderr}`);
    }
    const pages = {};
    for (const file of readdirSync(out, { recursive: true })) {
      if (file.endsWith('.html')) pages[file] = parse(readFileSync(join(out, file), 'utf8'));
    }
    for (const [path, page] of Object.entries(pages)) serializeMeta(serializeFootnotes(isolatePage(page, path), path), path);
    return pages;
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
}

export function typstMath(source) {
  return typstHTML(`#import "${rules}": html-rules\n#show: html-rules\n${source}\n`)
    .querySelectorAll('math')
    .map(math => math.toString());
}

/** The single <math> element of a snippet, parsed. */
export function only(mathml) {
  return parse(mathml).querySelector('math');
}
