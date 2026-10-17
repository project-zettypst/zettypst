// Moving rendered HTML fragments: every ID a fragment declares gets a fresh
// namespace, references follow, and URLs are rewritten for the destination.
import { posix } from 'node:path';

const origin = 'https://zettypst.invalid/';
const idLists = new Set(['for', 'headers', 'aria-labelledby', 'aria-describedby', 'aria-controls', 'aria-owns']);
const relative = (url, destination) => {
  if (url.origin !== new URL(origin).origin) return url.href;
  const path = posix.relative(posix.dirname(destination), decodeURI(url.pathname.slice(1)));
  return (path || posix.basename(destination)) + url.search + url.hash;
};

/**
 * Typst repeats glyph definitions across independent inline SVG frames, even
 * within one document. Give each outermost SVG of `root` its own namespace.
 * Returns the renamed IDs that were unique in `root`, so references from
 * outside a frame can follow them.
 */
export function isolateFrames(root, source, prefix) {
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
  return aliases;
}

export function relocate(root, source, destination, prefix) {
  const aliases = isolateFrames(root, source, prefix);
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

