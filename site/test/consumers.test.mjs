import assert from 'node:assert/strict';
import { test } from 'node:test';
import { typstBundle } from './typst.mjs';

const entry = `
#import ".zettypst/lib.typ": *
#let project = load()
#export-html(project, evaluate(project),
  render-unclassified: (source, reference) => {
    if reference.element != none and reference.element.func() == heading {
      link(reference.target, reference.element.body)
    } else { reference }
  },
)
`;
const a = `
#import "../.zettypst/lib.typ": *
#show: zettel
= A <a>
== Local <local-section>
See @local-section and #link(<local-section>)[local link], then @b.
`;
const b = `
#import "../.zettypst/lib.typ": *
#show: zettel
= B <b>
See @a.
`;

function check(page) {
  const ids = page.querySelectorAll('[id]').map(el => el.getAttribute('id'));
  assert.equal(ids.length, new Set(ids).size, 'display anchors must be unique');
  for (const a of page.querySelectorAll('a[href^="#"]')) {
    const id = decodeURIComponent(a.getAttribute('href').slice(1));
    assert.ok(ids.includes(id), 'missing local destination: ' + id);
  }
  assert.equal(page.querySelectorAll('[data-zk-transclusion]').length, 0);
}

test('local-label reproducer succeeds with the HTML consumer and isolated DOM copies', () => {
  const pages = typstBundle('edges', 'site.typ', { 'site.typ': entry, 'note/a.typ': a, 'note/b.typ': b });
  for (const page of Object.values(pages)) check(page);
  const copies = pages['b/index.html'].querySelectorAll('footer [data-zk-node="a"]');
  assert.equal(copies.length, 2);
  for (const copy of copies) {
    assert.equal(copy.querySelectorAll('footer').length, 0);
    assert.ok(copy.textContent.includes('See Local'));
    assert.ok(copy.querySelector('a[href^="#zk-copy-"]'));
  }
});

test('repeated body includes use the same consumer as relationship views', () => {
  const pages = typstBundle('edges', 'site.typ', {
    'site.typ': entry, 'note/a.typ': a,
    'note/b.typ': b + '\n#include-note[@a]\n#include-note[@a]\n',
  });
  for (const page of Object.values(pages)) check(page);
  assert.equal(pages['b/index.html'].querySelectorAll('body > section > details > [data-zk-main] > section[data-zk-node="a"]').length, 2);
});

test('nested HTML requests preserve relative and explicit placement separately', () => {
  const pages = typstBundle('edges', 'site.typ', {
    'site.typ': entry,
    '.zettypst/sources.typ': `
#let manifest() = (paths: ("note/a.typ", "note/b.typ", "note/c.typ"))
#let note(path) = include ("/" + path)
`,
    'note/a.typ': a,
    'note/b.typ': b + '\n#include-note(level: 2)[@a]\n#include-note[@a]\n',
    'note/c.typ': '#import "../.zettypst/lib.typ": *\n#show: zettel\n= C <c>\n#include-note[@b]\n',
  });
  for (const page of Object.values(pages)) check(page);
  const main = pages['c/index.html'].querySelector('body > section > details > [data-zk-main]');
  const copies = main.querySelectorAll('section[data-zk-node="a"]');
  assert.equal(copies.length, 2);
  assert.ok(copies[0].querySelector(':scope > section > details > summary h3'));
  assert.ok(copies[1].querySelector(':scope > section > details > summary h4'));
});

test('direct expansion remains an explicit consumer, including its native-label limitation', () => {
  assert.throws(() => typstBundle('edges', 'site.typ', {
    'site.typ': entry.replace('evaluate(project),',
      'evaluate(project), consume: kickstart.expand-transclusion,'),
    'note/a.typ': a, 'note/b.typ': b,
  }), /occurs multiple times/);
});

test('HTML requests do not evaluate the target body when consuming an embedding', () => {
  const pages = typstBundle('edges', 'site.typ', {
    'site.typ': entry.replace('evaluate(project),', 'evaluate(project), documents: ("b/index.html",),'),
    'note/a.typ': a + '\n#context panic("target body must not be laid out")\n',
    'note/b.typ': b + '\n#include-note[@a]\n',
  });
  assert.deepEqual(Object.keys(pages), ['b/index.html']);
  assert.ok(pages['b/index.html'].querySelector('[data-zk-transclusion="a"][data-zk-source="b"]'));
});
