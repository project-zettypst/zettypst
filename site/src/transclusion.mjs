// The HTML consumer: copy canonical mainmatter, never another card's footer.
// It runs after canonical math typesetting, so display copies do not re-typeset.
import { parse } from 'node-html-parser';
import { readFile, writeFile } from 'node:fs/promises';
import { resolve, sep, posix } from 'node:path';

const origin = 'https://zettypst.invalid/';
const idLists = new Set(['for', 'headers', 'aria-labelledby', 'aria-describedby', 'aria-controls', 'aria-owns']);
const relative = (url, destination) => {
  if (url.origin !== new URL(origin).origin) return url.href;
  const path = posix.relative(posix.dirname(destination), decodeURI(url.pathname.slice(1)));
  return (path || posix.basename(destination)) + url.search + url.hash;
};

function relocate(root, source, destination, prefix) {
  // Typst repeats glyph definitions across independent inline SVG frames.
  // Namespace each island first; article-level IDs still must be unique.
  const identities = root.querySelectorAll('[id]').map(el => el.id);
  const occupied = new Set(identities);
  const counts = new Map();
  for (const id of identities) counts.set(id, (counts.get(id) ?? 0) + 1);
  const aliases = new Map();
  let serial = 0;
  for (const svg of root.querySelectorAll('svg').filter(el => {
    const parent = el.parentNode.closest?.('svg');
    return !parent || parent === root;
  })) {
    let island;
    do { island = prefix + 'svg-' + (++serial) + '-'; }
    while ([...occupied].some(id => id.startsWith(island)));
    for (const [before, after] of relocate(svg, source, source, island)) {
      if (counts.get(before) === 1) aliases.set(before, after);
    }
  }
  const elements = root.querySelectorAll('*');
  const ids = new Map();
  for (const el of elements) {
    const id = el.getAttribute('id');
    if (!id) continue;
    if (ids.has(id)) throw new Error('Duplicate canonical fragment ID: ' + id);
    ids.set(id, prefix + id);
  }
  // Unique SVG targets may also be referenced by surrounding text or ARIA.
  for (const [before, after] of aliases) ids.set(before, ids.get(after));
  for (const el of elements) {
    for (const [name, value] of Object.entries(el.attributes)) {
      if (name === 'id') el.setAttribute(name, ids.get(value));
      else if (idLists.has(name)) el.setAttribute(name, value.split(/\s+/).map(id => ids.get(id) ?? id).join(' '));
      else if (name === 'href' || name === 'xlink:href' || name === 'src') {
        const url = new URL(value, new URL(source, origin));
        const local = decodeURIComponent(url.hash.slice(1));
        if (url.origin === new URL(origin).origin && url.pathname === new URL(source, origin).pathname && ids.has(local)) {
          el.setAttribute(name, '#' + ids.get(local));
        } else if (!value.startsWith('data:')) el.setAttribute(name, relative(url, destination));
      } else if (value.includes('url(#')) {
        el.setAttribute(name, value.replace(/url\(#([^)]+)\)/g, (_, id) => 'url(#' + (ids.get(id) ?? id) + ')'));
      }
    }
  }
  return ids;
}

function heading(element, offset) {
  const current = Number(element.tagName.slice(1));
  const level = current + offset;
  if (level < 1 || level > 6) throw new Error('Transclusion heading exceeds HTML h1–h6');
  element.tagName = 'h' + level;
}

export function canonicalMains(pages, index) {
  const mains = new Map();
  for (const entry of index) {
    const page = pages.get(entry.route);
    if (!page) throw new Error('Missing canonical page: ' + entry.route);
    // Never select nested display instances or preview templates.
    const card = page.querySelectorAll('body > section[data-zk-node]')
      .find(node => node.getAttribute('data-zk-node') === entry.id);
    const main = card?.querySelector(':scope > details > [data-zk-main]');
    if (!main) throw new Error('Missing canonical mainmatter: ' + entry.id);
    mains.set(entry.id, { route: entry.route, html: main.innerHTML });
  }
  return mains;
}

export function materialize(page, destination, mains) {
  let serial = 0;
  const used = new Set(page.querySelectorAll('[id]').map(el => el.getAttribute('id')));
  const expand = (within, offset = 0, trail = []) => {
    // Only this level's requests; nested requests are instantiated recursively.
    const slots = within.querySelectorAll('[data-zk-transclusion]');
    for (const slot of slots) {
      if (!slot.parentNode) continue;
      const target = slot.getAttribute('data-zk-transclusion');
      if (trail.includes(target)) throw new Error('Transclusion cycle: ' + [...trail, target].join(' -> '));
      const canonical = mains.get(target);
      if (!canonical) throw new Error('Unpublished or missing transclusion target: ' + target);
      const initial = Number(slot.getAttribute('data-zk-level'));
      if (!Number.isInteger(initial) || initial < 1) throw new Error('Invalid transclusion level');
      const shift = slot.getAttribute('data-zk-relative') === 'true' ? offset : 0;
      const level = initial + shift;
      const details = slot.parentNode;
      const summary = details.querySelector(':scope > summary');
      if (!summary) throw new Error('Transclusion view must place its slot directly inside details');
      for (const h of summary.querySelectorAll('h1,h2,h3,h4,h5,h6')) heading(h, shift);
      let prefix;
      do { prefix = 'zk-copy-' + (++serial) + '-'; }
      while ([...used].some(id => id.startsWith(prefix)));
      const copy = parse('<div data-zk-main-copy>' + canonical.html + '</div>').firstChild;
      relocate(copy, canonical.route, destination, prefix);
      for (const el of copy.querySelectorAll('[id]')) used.add(el.getAttribute('id'));
      // Child request summaries have their own placement policy.
      for (const h of copy.querySelectorAll('h1,h2,h3,h4,h5,h6')) {
        if (!h.closest('details')?.querySelector(':scope > [data-zk-transclusion]')) heading(h, level - 1);
      }
      expand(copy, level - 1, [...trail, target]);
      slot.replaceWith(copy);
    }
  };
  expand(page);
  return page;
}

export async function materializeDirectory(directory) {
  const index = JSON.parse(await readFile(resolve(directory, 'zettypst.json'), 'utf8'));
  const routes = [...new Set(index.map(entry => entry.route))];
  const safe = route => {
    const path = resolve(directory, route);
    if (!path.startsWith(resolve(directory) + sep)) throw new Error('Publication route escapes output');
    return path;
  };
  // Snapshot only canonical fragments; hold one document DOM at a time.
  const mains = new Map();
  for (const route of routes) {
    const page = parse(await readFile(safe(route), 'utf8'));
    for (const [id, main] of canonicalMains(new Map([[route, page]]),
      index.filter(entry => entry.route === route))) mains.set(id, main);
  }
  for (const route of routes) {
    const page = parse(await readFile(safe(route), 'utf8'));
    await writeFile(safe(route), materialize(page, route, mains).toString());
  }
}
