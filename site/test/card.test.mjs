// The view contract between Typst and the site: a view never repeats the
// note's own label, marks what it shows, and leaves numbering untouched.
import assert from 'node:assert/strict';
import { describe, test } from 'node:test';
import { sources, typstHTML } from './typst.mjs';

// A note as export-html hands it to a card; refs render as plain links.
const card = (views, body = '[= Note <n>\nText.]', after = '') => typstHTML(`
#set math.equation(numbering: "(1)")
#import "${sources.kickstart}": without-root
#import "${sources.kickstart}": site
#import site: card
#show ref: it => if it.target != <n> { it } else { link(it.target, if it.supplement in (auto, none) [Note] else { it.supplement }) }
#let body = ${body}
#let note = (
  id: "n", title: [Note], body: body, main: without-root(body, "n"),
  metadata: (tags: ("fixture",), abstract: ""), backlinks: (), links: (),
)
#html.elem("section", attrs: ("data-zk-node": "n"), card(note, views: ${views}))
${after}
`);

describe('without-root', () => {
  test('removes only the root heading, through sequences and styles', () => {
    const page = typstHTML(`
#import "${sources.kickstart}": without-root
#let body = [#set text(weight: "bold")
= Note <n>
== Section <s>
Text.]
#html.elem("div", attrs: (id: "main"), without-root(body, "n"))
`);
    const main = page.querySelector('#main');
    assert.equal(main.querySelectorAll('h2').length, 0);
    assert.equal(main.querySelectorAll('h3').length, 1);
    assert.match(main.text, /Text\./);
  });
});

describe('views', () => {
  test('auto views mark the card body in place', () => {
    const page = card('(:)');
    assert.equal(page.querySelector('details').getAttribute('data-zk-view'), 'preview expand');
  });
  test('about is left to the metadata island unless declared', () => {
    const page = card('(:)');
    assert.equal(page.querySelector('template[data-zk-view="about"]'), null);
    const record = JSON.parse(page.querySelector('section > script[data-zk-meta]').rawText);
    assert.deepEqual(record, {
      version: 1, id: 'n', title: { $slot: 0 },
      metadata: { tags: ['fixture'], abstract: '' },
      relations: { context: [], backlinks: [], links: [] },
    });
    assert.equal(page.querySelector('template[data-zk-meta-slot="0"]').text, 'Note');
  });
  test('content views are inert templates; none is an empty one', () => {
    const page = card('(preview: note => [Abstract.], expand: note => none)');
    assert.equal(page.querySelector('details').getAttribute('data-zk-view'), undefined);
    assert.equal(page.querySelector('template[data-zk-view="preview"]').text, 'Abstract.');
    assert.equal(page.querySelector('template[data-zk-view="expand"]').text, '');
  });
  test('note.main repeats the body without duplicating the note label', () => {
    // A duplicated, referenced label would fail to compile.
    const page = card('(expand: note => note.main)', '[= Note <n>\nText, see @n.]');
    assert.equal(page.querySelectorAll('[id="n"]').length, 1);
    assert.match(page.querySelector('template[data-zk-view="expand"]').text, /Text/);
  });
  test('views do not advance counters', () => {
    // The view repeats two numbered equations; the one after the card is still third.
    const page = card(
      '(expand: note => note.main)',
      '[= Note <n>\n$ a $\n$ b $]',
      '$ c $ <after>\n\nSee @after.',
    );
    assert.equal(page.querySelectorAll('template[data-zk-view="expand"] math').length, 2);
    assert.match(page.querySelector('body').text, /See Equation\s3/);
  });
});
