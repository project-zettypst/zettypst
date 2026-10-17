// One canonical page: Typst repeats definitions across frames, and the site
// gives each frame its own namespace before any fragment moves.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { parse } from 'node-html-parser';
import { isolatePage } from '../src/fragments.mjs';
import { typstHTML } from './typst.mjs';

test('identical frames in one document get disjoint IDs', () => {
  const frame = '#html.frame(rect(fill: gradient.linear(red, blue))[abc $x^2$])';
  const page = typstHTML(frame + frame);
  const before = page.querySelectorAll('[id]').map(el => el.id);
  assert.ok(before.length > new Set(before).size, 'Typst repeats frame definitions');
  isolatePage(page, 'n/index.html');
  const ids = page.querySelectorAll('[id]').map(el => el.id);
  assert.equal(ids.length, new Set(ids).size);
  for (const svg of page.querySelectorAll('svg')) {
    const own = new Set(svg.querySelectorAll('[id]').map(el => el.id));
    for (const use of svg.querySelectorAll('use')) {
      const href = use.getAttribute('href') ?? use.getAttribute('xlink:href');
      assert.ok(own.has(href.slice(1)), 'frame references its own definition: ' + href);
    }
  }
});

test('references outside a frame follow its unique IDs; other duplicates fail', () => {
  const page = isolatePage(parse('<body><a href="#t">t</a><svg><title id="t">T</title></svg></body>'), 'n/index.html');
  assert.equal(page.querySelector('a').getAttribute('href'), '#' + page.querySelector('title').id);
  assert.throws(() => isolatePage(parse('<body><p id="x"></p><p id="x"></p></body>'), 'n/index.html'), /Duplicate ID x/);
});
