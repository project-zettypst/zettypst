// One canonical page: Typst repeats definitions across frames, and the site
// gives each frame its own namespace before any fragment moves.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { parse } from 'node-html-parser';
import { isolatePage, relocate } from '../src/fragments.mjs';
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

test('relocation repairs anchors, ID lists, SVG and asset paths for its destination', () => {
  const fragment = () => parse(`<div><h3 id="local">Local</h3>
<a href="index.html#local">local</a><a href="https://example.org/a/index.html#local">external</a>
<p aria-labelledby="local">label</p><img src="../asset.svg"><a href="../b/index.html#x">other</a>
<p aria-describedby="chart-title"><a href="#chart-title">chart</a></p>
<svg><title id="chart-title">Chart</title><defs><path id="glyph"></path></defs><use href="#glyph"></use></svg>
<svg><defs><path id="glyph"></path></defs><use xlink:href="#glyph"></use>
<svg><defs><path id="glyph"></path></defs><use href="#glyph"></use></svg></svg></div>`).firstChild;
  const copies = ['p1-', 'p2-'].map(prefix => {
    const copy = fragment();
    relocate(copy, 'a/index.html', 'b/deep/index.html', prefix);
    return copy;
  });
  const ids = copies.flatMap(copy => copy.querySelectorAll('[id]').map(el => el.id));
  assert.equal(ids.length, new Set(ids).size);
  for (const copy of copies) {
    const local = copy.querySelector('h3').id;
    const links = copy.querySelectorAll('a');
    assert.equal(links[0].getAttribute('href'), '#' + local);
    assert.equal(links[1].getAttribute('href'), 'https://example.org/a/index.html#local');
    assert.equal(links[2].getAttribute('href'), '../index.html#x');
    assert.equal(copy.querySelector('p').getAttribute('aria-labelledby'), local);
    assert.equal(copy.querySelector('img').getAttribute('src'), '../../asset.svg');
    const title = copy.querySelector('svg title').id;
    assert.equal(copy.querySelector('[aria-describedby]').getAttribute('aria-describedby'), title);
    assert.equal(copy.querySelector('[aria-describedby] a').getAttribute('href'), '#' + title);
    for (const svg of copy.querySelectorAll('svg')) {
      const use = svg.querySelector('use');
      assert.equal(use.getAttribute('href') ?? use.getAttribute('xlink:href'), '#' + svg.querySelector('path').id);
    }
  }
  const duplicate = parse('<div><h3 id="same">A</h3><h3 id="same">B</h3></div>').firstChild;
  assert.throws(() => relocate(duplicate, 'a/index.html', 'a/index.html', 'p-'), /Duplicate canonical fragment ID/);
});
