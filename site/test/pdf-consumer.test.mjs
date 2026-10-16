import assert from 'node:assert/strict';
import { test } from 'node:test';
import { spawnSync } from 'node:child_process';
import { cpSync, mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';

const repository = fileURLToPath(new URL('../../', import.meta.url));
function compile(entry, root, packages) {
  return spawnSync('typst', ['compile', '--root', root,
    ...(packages ? ['--package-path', packages] : []), entry, join(root, 'out.pdf')],
  { encoding: 'utf8', timeout: 10000, maxBuffer: 1024 * 1024 });
}
function fixture(t, deferred = false) {
  const root = mkdtempSync(join(tmpdir(), 'zettyp-pdf-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const packages = join(root, 'packages');
  const pkg = join(packages, 'preview/zettyp/0.1.0');
  mkdirSync(pkg, { recursive: true });
  cpSync(join(repository, 'typst'), pkg, { recursive: true });
  cpSync(join(repository, 'typst/kickstart/template/.zettypst'), join(root, '.zettypst'), { recursive: true });
  mkdirSync(join(root, 'note'));
  writeFileSync(join(root, '.zettypst/source.toml'), 'paths = ["note/a.typ", "note/b.typ", "note/c.typ"]');
  const note = (id, body) => '#import "../.zettypst/lib.typ": *\n#show: zettel\n= ' + id + ' <' + id + '>\n' + body;
  writeFileSync(join(root, 'note/a.typ'), note('a', deferred
    ? '#context [\n== Local <local>\n]\nSee @local.'
    : '== Local <local>\nSee @local and #link(<local>)[jump].'));
  writeFileSync(join(root, 'note/b.typ'), note('b', '#include-note[@a]\n#include-note[@c]'));
  writeFileSync(join(root, 'note/c.typ'), note('c', '#include-note[@a]'));
  cpSync(join(repository, 'typst/kickstart/template/index.typ'), join(root, 'index.typ'));
  return { root, packages };
}

test('PDF template isolates local labels in direct and indirect repeated includes', t => {
  const { root, packages } = fixture(t);
  writeFileSync(join(root, 'test.typ'), `
#include "index.typ"
#context {
  let local = query(heading).filter(it => it.body == [Local])
  assert.eq(local.len(), 4)
  assert.eq(local.map(it => it.label).dedup().len(), 4)
}
`);
  const result = compile(join(root, 'test.typ'), root, packages);
  assert.equal(result.status, 0, result.stderr);
  assert.doesNotMatch(result.stderr, /did not converge/);
});

test('PDF consumer rejects deferred labels explicitly', t => {
  const { root, packages } = fixture(t, true);
  const result = compile(join(root, 'index.typ'), root, packages);
  assert.equal(result.status, 1, result.stderr);
  assert.match(result.stderr, /labels must be available before layout/);
});

test('native heading, equation, figure and footnote references survive repeated PDF instances', t => {
  const out = mkdtempSync(join(tmpdir(), 'zettyp-pdf-numbered-'));
  t.after(() => rmSync(out, { recursive: true, force: true }));
  const result = spawnSync('typst', [
    'compile', '--root', repository, join(repository, 'typst/kickstart/tests/consumers.typ'), join(out, 'out.pdf'),
  ], { encoding: 'utf8', timeout: 10000 });
  assert.equal(result.status, 0, result.stderr);
  assert.doesNotMatch(result.stderr, /did not converge/);
});
