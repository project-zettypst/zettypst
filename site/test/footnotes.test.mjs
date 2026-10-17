// Footnotes: Typst lays each body out once, in its endnotes; the site moves it
// into every reference, and links into a body land on its first reference.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { parse } from 'node-html-parser';
import { serializeFootnotes } from '../src/footnotes.mjs';
import { typstBundle, typstHTML } from './typst.mjs';

const card = body => typstHTML(`
#set math.equation(numbering: "(1)")
#html.elem("section", attrs: ("data-zk-node": "n"))[${body}]
`);
const ids = page => page.querySelectorAll('[id]').map(el => el.getAttribute('id'));

test('each reference carries its body, and the endnotes disappear', () => {
  const page = serializeFootnotes(card(
    'A#footnote[Body *b* $ y $ <eq>]<f> again#footnote(<f>), B#footnote[Other]. See @eq.',
  ), 'n/index.html');
  assert.equal(page.querySelectorAll('section[role="doc-endnotes"]').length, 0);
  const refs = page.querySelectorAll('sup[role="doc-noteref"]');
  assert.deepEqual(refs.map(ref => ref.firstChild.text), ['1', '1', '2']);
  assert.equal(page.querySelectorAll('sup[role="doc-noteref"] a').length, 0);
  const bodies = refs.map(ref => ref.querySelector(':scope > template[data-zk-footnote]'));
  assert.ok(bodies[0].querySelector('strong') && bodies[0].querySelector('math'));
  assert.equal(bodies[2].text, 'Other');
  assert.equal(page.querySelectorAll('sup[role="doc-backlink"]').length, 0);
  // Repeated bodies are namespaced; every ID is unique.
  assert.equal(ids(page).length, new Set(ids(page)).size);
  assert.notEqual(bodies[0].querySelector('math').id, bodies[1].querySelector('math').id);
  // The equation left the document with its footnote: its ref lands on the reference.
  const outside = page.querySelectorAll('a[href^="#"]').filter(a => !a.closest('template'));
  assert.deepEqual(outside.map(a => a.getAttribute('href')), ['#' + refs[0].id]);
});

test('links inside a body keep their targets', () => {
  const page = serializeFootnotes(card('A#footnote[$ y $ <eq> see @eq]'), 'n/index.html');
  const body = page.querySelector('template[data-zk-footnote]');
  assert.equal(body.querySelector('a').getAttribute('href'), '#' + body.querySelector('math').id);
});

test('malformed footnotes fail the build', () => {
  assert.throws(() => serializeFootnotes(parse('<body><p><sup role="doc-noteref"><a href="#x">1</a></sup></p>'
    + '<section role="doc-endnotes"><ol><li id="x"><sup role="doc-backlink"><a href="#r">1</a></sup>B</li></ol></section></body>'),
  'n/index.html'), /outside a card/);
  assert.throws(() => serializeFootnotes(parse('<body><section data-zk-node="n"><sup role="doc-noteref"><a href="#y">1</a></sup></section></body>'),
    'n/index.html'), /Missing footnote/);
});

test('footnotes in published cards survive transclusion', () => {
  const pages = typstBundle('edges', 'site.typ', {
    'note/a.typ': '#import "../.zettypst/lib.typ": *\n#show: zettel.with(metadata: zk_metadata.with(tags: ("fixture",)))\n= Note A <a>\nA#footnote[Body of A].\n',
    'note/b.typ': '#import "../.zettypst/lib.typ": *\n#show: zettel.with(metadata: zk_metadata)\n= Note B <b>\n#include-note[@a]\n',
  });
  for (const page of Object.values(pages)) {
    assert.equal(page.querySelectorAll('section[role="doc-endnotes"]').length, 0);
    assert.equal(ids(page).length, new Set(ids(page)).size);
  }
  const copy = pages['b/index.html'].querySelector('[data-zk-main] sup[role="doc-noteref"] > template[data-zk-footnote]');
  assert.equal(copy?.text, 'Body of A');
});
