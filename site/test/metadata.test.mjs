// The metadata island contract: Typst encodes values and content slots, the
// site replaces slots with HTML and leaves one JSON record per card.
import assert from 'node:assert/strict';
import { describe, test } from 'node:test';
import { parse } from 'node-html-parser';
import { serializeMeta } from '../src/metadata.mjs';
import { sources, typstBundle, typstHTML } from './typst.mjs';

const island = page => JSON.parse(page.querySelector('script[data-zk-meta]').rawText);

describe('Typst encoding', () => {
  const encoded = metadata => typstHTML(`
#import "${sources.site}": meta-island
#html.elem("section", attrs: ("data-zk-node": "n"), meta-island("n", title: [N],
  metadata: ${metadata}, nodes: ("replaced-by",), relations: (backlinks: ("b",))))
`);
  test('values keep their JSON types; content becomes a slot', () => {
    const page = encoded(`(
      lifecycle: (type: "lifecycle", variant: "legacy", value: "legacy"),
      tags: ("a<b", "</script>"), count: 2, ratio: 0.5, open: true, empty: none,
      record: (k: "v"), abstract: [An *abstract*], replaced-by: ("old",),
    )`);
    const record = island(page);
    assert.deepEqual(record.metadata, {
      lifecycle: 'legacy', tags: ['a<b', '</script>'], count: 2, ratio: 0.5, open: true,
      empty: null, record: { k: 'v' }, abstract: { $slot: 1 }, 'replaced-by': [{ $node: 'old' }],
    });
    assert.deepEqual(record.relations, { backlinks: [{ $node: 'b' }] });
    assert.equal(page.querySelector('template[data-zk-meta-slot="1"] strong').text, 'abstract');
    assert.doesNotMatch(page.querySelector('script[data-zk-meta]').rawText, /</);
  });
  test('reserved keys and unsupported values fail', () => {
    assert.throws(() => encoded('(x: ("$html": "y"),)'), /reserved/);
    assert.throws(() => encoded('(x: datetime(year: 2026, month: 1, day: 1),)'), /unsupported/);
  });
});

describe('site serialization', () => {
  const card = (json, slots = '') => parse(`<body><section data-zk-node="n">
<script type="application/json" data-zk-meta>${json}</script>${slots}<details></details></section></body>`);
  test('slots become HTML with namespaced IDs, and templates disappear', () => {
    const page = card('{"version":1,"id":"n","title":{"$slot":0},"metadata":{"a":[{"$slot":1}]}}',
      '<template data-zk-meta-slot="0">N</template>'
      + '<template data-zk-meta-slot="1"><b id="x">B</b> <a href="#x">x</a></template>');
    serializeMeta(page, 'n/index.html');
    assert.equal(page.querySelectorAll('template').length, 0);
    const record = island(page);
    assert.deepEqual(record.title, { $html: 'N' });
    const fragment = parse(record.metadata.a[0].$html);
    const id = fragment.querySelector('b').id;
    assert.match(id, /^zk-meta-\d+-x$/);
    assert.equal(fragment.querySelector('a').getAttribute('href'), '#' + id);
    assert.doesNotMatch(page.querySelector('script').rawText, /</);
  });
  test('malformed islands fail the build', () => {
    const fails = (page, pattern) => assert.throws(() => serializeMeta(page, 'n/index.html'), pattern);
    fails(card('{'), /Invalid/);
    fails(card('{"version":2}'), /version/);
    fails(card('{"version":1,"t":{"$slot":0}}'), /Missing metadata slot/);
    fails(card('{"version":1}', '<template data-zk-meta-slot="0">x</template>'), /Unused/);
    fails(card('{"version":1}', '<script type="application/json" data-zk-meta>{}</script>'), /Several/);
    fails(parse('<body><div><script data-zk-meta>{}</script></div></body>'), /outside a card/);
  });
  test('published cards carry their graph neighbourhood', () => {
    const pages = typstBundle('edges');
    const a = island(pages['a/index.html']);
    assert.deepEqual(a.title, { $html: 'Note A' });
    assert.deepEqual(a.metadata.tags, ['fixture']);
    assert.deepEqual(a.relations.backlinks, [{ $node: 'b' }]);
    assert.equal(pages['a/index.html'].querySelectorAll('template[data-zk-meta-slot]').length, 0);
  });
});
