// Every rendered note link names both endpoints of its edge, as the kickstart
// knows them while rendering: the site never infers either one, so links keep
// their meaning wherever a card's content is moved (stack, preview, expansion).
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { typstBundle } from './typst.mjs';

const pages = typstBundle('edges');
const links = within => within.querySelectorAll('.zk-link').map(it => [
  it.getAttribute('data-zk-source'), it.getAttribute('data-zk-target'),
]);
const card = path => pages[path].querySelector('section[data-zk-node]');

test('links in a card are that card\'s edges', () => {
  const body = card('a/index.html').querySelector(':scope > details');
  assert.deepEqual(links(body), [['a', 'a'], ['a', 'b'], ['a', 'a']]);
  assert.deepEqual(links(card('b/index.html').querySelector(':scope > details')), [['b', 'b'], ['b', 'a']]);
});

test('copies in views keep their source card', () => {
  const expand = card('a/index.html').querySelector('template[data-zk-view="expand"]');
  assert.deepEqual(links(expand), [['a', 'b'], ['a', 'a']]);
});

test('relationship entries embed the target without changing its link ownership', () => {
  const footer = card('b/index.html').querySelector(':scope > footer');
  const copies = footer.querySelectorAll('section[data-zk-node="a"]');
  assert.ok(copies.length > 0);
  for (const copy of copies) {
    assert.deepEqual(links(copy), [['a', 'a'], ['a', 'b'], ['a', 'a']]);
    assert.equal(copy.querySelectorAll('footer').length, 0);
  }
});
