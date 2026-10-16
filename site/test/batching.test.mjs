import assert from 'node:assert/strict';
import { test } from 'node:test';
import { typstBundle } from './typst.mjs';

const entry = documents => `
#import ".zettypst/lib.typ": evaluate, export-html, load
#let project = load()
#export-html(project, evaluate(project), documents: ${documents})
`;

test('document batches keep external routes and canonical anchors', () => {
  const all = typstBundle('edges', 'site.typ', { 'site.typ': entry('auto') });
  for (const name of ['a', 'b']) {
    const path = name + '/index.html';
    const batch = typstBundle('edges', 'site.typ', { 'site.typ': entry('("' + path + '",)') });
    assert.deepEqual(Object.keys(batch), [path]);
    const links = page => page.querySelector('body > section > details > [data-zk-main]')
      .querySelectorAll('.zk-link a').map(a => a.getAttribute('href'));
    assert.deepEqual(links(batch[path]), links(all[path]));
    for (const href of links(batch[path])) {
      const url = new URL(href, 'https://example.test/' + path);
      const target = all[url.pathname.slice(1)];
      assert.ok(target, href);
      assert.ok(target.querySelector(url.hash), href);
    }
  }
});

test('numbered figures in many documents and copied backmatter converge', () => {
  const ids = Array.from({ length: 12 }, (_, i) => 'figure' + i);
  const sources = {
    'site.typ': entry('auto'),
    '.zettypst/sources.typ': `
#let manifest() = (paths: (${ids.map(id => '"note/' + id + '.typ"').join(',')},))
#let note(path) = include ("/" + path)
`,
  };
  for (const id of ids) {
    sources['note/' + id + '.typ'] = `
#import "../.zettypst/lib.typ": *
#show: zettel
= ${id} <${id}>
#figure(html.frame(rect(width: 1cm, height: 1cm)), kind: image, caption: [Figure])
${ids.filter(other => other !== id).map(other => '@' + other).join(' ')}
`;
  }
  assert.equal(Object.keys(typstBundle('edges', 'site.typ', sources)).length, ids.length);
});

test('an index-only pass renders no node documents', () => {
  assert.deepEqual(typstBundle('edges', 'site.typ', { 'site.typ': entry('()') }), {});
});
