import assert from 'node:assert/strict';
import { test } from 'node:test';
import { mkdtemp, mkdir, writeFile, readFile, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { parse } from 'node-html-parser';
import { materializeDirectory, materialize } from '../src/transclusion.mjs';

test('static directory consumption repairs anchors, ID lists, SVG and asset paths', async t => {
  const root = await mkdtemp(join(tmpdir(), 'zettyp-static-consumer-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  await mkdir(join(root, 'a'), { recursive: true });
  await mkdir(join(root, 'b/deep'), { recursive: true });
  await writeFile(join(root, 'zettypst.json'), JSON.stringify([
    { id: 'a', route: 'a/index.html' }, { id: 'b', route: 'b/deep/index.html' },
  ]));
  await writeFile(join(root, 'a/index.html'), `<body><section data-zk-node="a"><details>
<summary>A</summary><div data-zk-main><h3 id="local">Local</h3>
<a href="index.html#local">local</a><a href="https://example.org/a/index.html#local">external</a>
<p aria-labelledby="local">label</p><img src="../asset.svg">
<p aria-describedby="chart-title"><a href="#chart-title">chart</a></p>
<svg><title id="chart-title">Chart</title><defs><path id="glyph"></path></defs><use href="#glyph"></use></svg>
<svg><defs><path id="glyph"></path></defs><use xlink:href="#glyph"></use>
<svg><defs><path id="glyph"></path></defs><use href="#glyph"></use></svg></svg>
</div></details></section></body>`);
  const request = '<section data-zk-node="a"><details><summary><h3>A</h3></summary><div data-zk-transclusion="a" data-zk-level="2" data-zk-relative="true"></div></details></section>';
  await writeFile(join(root, 'b/deep/index.html'), '<body><section data-zk-node="b"><details><summary>B</summary><div data-zk-main>'
    + request + request + '</div></details></section></body>');
  await materializeDirectory(root);
  const page = parse(await readFile(join(root, 'b/deep/index.html'), 'utf8'));
  const copies = page.querySelectorAll('[data-zk-main-copy]');
  assert.equal(copies.length, 2);
  const ids = page.querySelectorAll('[id]').map(el => el.id);
  assert.equal(ids.length, new Set(ids).size);
  for (const copy of copies) {
    const local = copy.querySelector('h4').id;
    assert.equal(copy.querySelector('a').getAttribute('href'), '#' + local);
    assert.equal(copy.querySelector('p').getAttribute('aria-labelledby'), local);
    assert.equal(copy.querySelector('img').getAttribute('src'), '../../asset.svg');
    const title = copy.querySelector('svg title').id;
    assert.equal(copy.querySelector('[aria-describedby]').getAttribute('aria-describedby'), title);
    assert.equal(copy.querySelector('[aria-describedby] a').getAttribute('href'), '#' + title);
    for (const svg of copy.querySelectorAll('svg')) {
      const use = svg.querySelector('use');
      assert.equal(use.getAttribute('href') ?? use.getAttribute('xlink:href'), '#' + svg.querySelector('path').id);
    }
    assert.equal(copy.querySelectorAll('a')[1].getAttribute('href'), 'https://example.org/a/index.html#local');
  }
});

test('HTML consumers reject unpublished targets and recursive artifact requests', () => {
  const slot = id => parse('<details><summary>A</summary><div data-zk-transclusion="' + id
    + '" data-zk-level="2" data-zk-relative="true"></div></details>');
  assert.throws(() => materialize(slot('hidden'), 'index.html', new Map()), /Unpublished/);
  const duplicate = new Map([['a', { route: 'a/index.html', html: '<h3 id="same">A</h3><h3 id="same">B</h3>' }]]);
  assert.throws(() => materialize(slot('a'), 'index.html', duplicate), /Duplicate canonical fragment ID/);
  const cyclic = new Map([['a', { route: 'a/index.html', html: slot('a').toString() }]]);
  assert.throws(() => materialize(slot('a'), 'index.html', cyclic), /cycle/);
});
