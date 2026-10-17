// Card metadata islands (data-zk-meta, version 1). Typst writes each canonical
// card's metadata as JSON whose content values are numbered slots, rendered in
// sibling <template data-zk-meta-slot=n> elements. After math typesetting, the
// site moves each slot's HTML into its value as {"$html": "..."} and removes
// the templates, so a published card holds its metadata exactly once.
import { parse } from 'node-html-parser';
import { relocate } from './fragments.mjs';

const isCard = node => node?.getAttribute?.('data-zk-node') != null && node.tagName === 'SECTION';
// "<" never appears literally, so the JSON cannot close its script element.
const encode = record => JSON.stringify(record).replace(/</g, '\\u003c');

export function serializeMeta(page, route) {
  for (const el of page.querySelectorAll('script[data-zk-meta], template[data-zk-meta-slot]')) {
    if (!isCard(el.parentNode)) throw new Error('Metadata outside a card in ' + route);
  }
  const used = new Set(page.querySelectorAll('[id]').map(el => el.getAttribute('id')));
  let serial = 0;
  for (const card of page.querySelectorAll('section[data-zk-node]')) {
    const id = card.getAttribute('data-zk-node');
    const islands = card.querySelectorAll(':scope > script[data-zk-meta]');
    const slots = card.querySelectorAll(':scope > template[data-zk-meta-slot]');
    if (islands.length > 1) throw new Error('Several metadata islands for ' + id);
    if (islands.length === 0) {
      if (slots.length) throw new Error('Metadata slots without an island for ' + id);
      continue;
    }
    let record;
    try { record = JSON.parse(islands[0].rawText); } catch { throw new Error('Invalid metadata island for ' + id); }
    if (record?.version !== 1) throw new Error('Unsupported metadata island version for ' + id);
    const html = new Map();
    for (const slot of slots) {
      const index = slot.getAttribute('data-zk-meta-slot');
      if (html.has(index)) throw new Error('Duplicate metadata slot ' + index + ' for ' + id);
      let prefix;
      do { prefix = 'zk-meta-' + (++serial) + '-'; }
      while ([...used].some(it => it.startsWith(prefix)));
      const fragment = parse('<div>' + slot.innerHTML + '</div>').firstChild;
      relocate(fragment, route, route, prefix);
      for (const el of fragment.querySelectorAll('[id]')) used.add(el.getAttribute('id'));
      html.set(index, fragment.innerHTML);
      slot.remove();
    }
    const fill = value => {
      if (Array.isArray(value)) return value.map(fill);
      if (value === null || typeof value !== 'object') return value;
      if ('$slot' in value) {
        const index = String(value.$slot);
        if (!html.has(index)) throw new Error('Missing metadata slot ' + index + ' for ' + id);
        const fragment = html.get(index);
        html.delete(index);
        return { $html: fragment };
      }
      return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, fill(item)]));
    };
    record = fill(record);
    if (html.size) throw new Error('Unused metadata slots for ' + id);
    islands[0].set_content(encode(record));
  }
  return page;
}
