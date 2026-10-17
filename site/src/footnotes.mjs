// Footnotes, as Typst's HTML export marks them (DPub-ARIA): references are
// `sup[role=doc-noteref] > a[href="#note"]`, and each body is laid out once, in
// a `section[role=doc-endnotes]` outside every card. After math typesetting,
// the site moves each body into an inert `<template data-zk-footnote>` inside
// every reference to it and removes the endnotes, so a card holds its
// footnotes. IDs leave the document with their footnote: links to them land
// on the footnote's first reference, the target of its own backlink.
import { parse } from 'node-html-parser';
import { relocate } from './fragments.mjs';

const isCard = node => node?.tagName === 'SECTION' && node.getAttribute('data-zk-node') != null;
const local = el => {
  const href = el.getAttribute('href');
  return href?.startsWith('#') ? decodeURIComponent(href.slice(1)) : null;
};

export function serializeFootnotes(page, route) {
  const bodies = new Map();
  const anchors = new Map();
  // Every ID declared in a footnote body, by the footnote that declares it.
  const owners = new Map();
  for (const list of page.querySelectorAll('section[role="doc-endnotes"]')) {
    for (const item of list.querySelectorAll('li')) {
      const id = item.getAttribute('id');
      const back = item.querySelector('sup[role="doc-backlink"]');
      const anchor = back && back.querySelector('a') && local(back.querySelector('a'));
      if (!id || !anchor) throw new Error('Unrecognized footnote in ' + route);
      back.remove();
      for (const el of [item, ...item.querySelectorAll('[id]')]) owners.set(el.getAttribute('id'), id);
      anchors.set(id, anchor);
      bodies.set(id, item);
    }
  }
  const retarget = (el, within) => {
    const id = local(el);
    const owner = id === null ? undefined : owners.get(id);
    if (owner !== undefined && owner !== within) el.setAttribute('href', '#' + anchors.get(owner));
  };
  // Links inside a body keep their own targets, which travel with it.
  for (const [id, item] of bodies) for (const el of item.querySelectorAll('[href]')) retarget(el, id);
  const html = new Map([...bodies].map(([id, item]) => [id, item.innerHTML]));
  for (const list of page.querySelectorAll('section[role="doc-endnotes"]')) list.remove();

  const refs = page.querySelectorAll('sup[role="doc-noteref"]').map(ref => {
    if (!isCard(ref.closest('section[data-zk-node]'))) throw new Error('Footnote outside a card in ' + route);
    const link = ref.querySelector('a');
    const id = link && local(link);
    if (!html.has(id)) throw new Error('Missing footnote ' + id + ' in ' + route);
    // The number stays; its endnote does not.
    link.replaceWith(...link.childNodes);
    return [ref, id];
  });
  for (const el of page.querySelectorAll('[href]')) retarget(el, undefined);

  const used = new Set(page.querySelectorAll('[id]').map(el => el.getAttribute('id')));
  let serial = 0;
  for (const [ref, id] of refs) {
    let prefix;
    do { prefix = 'zk-note-' + (++serial) + '-'; }
    while ([...used].some(it => it.startsWith(prefix)));
    const body = parse('<template data-zk-footnote>' + html.get(id) + '</template>').firstChild;
    relocate(body, route, route, prefix);
    for (const el of body.querySelectorAll('[id]')) used.add(el.getAttribute('id'));
    ref.appendChild(body);
  }
  return page;
}
