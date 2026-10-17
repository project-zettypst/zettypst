// Card metadata as the site published it (`script[data-zk-meta]`): JSON whose
// values are scalars, HTML fragments ({"$html"}) and note references
// ({"$node"}). Rendering depends on value types only, never on field names.
import { entries, manifest, routeURL } from './cards';

type Value = null | string | number | boolean | Value[] | { [key: string]: Value };
export type MetaRecord = {
  version: 1;
  id: string;
  title: Value;
  metadata: Record<string, Value>;
  relations: Record<string, Value[]>;
};

/** The card's own metadata record, if it published one. */
export function readMeta(card: Element): MetaRecord | null {
  const island = card.querySelector(':scope > script[data-zk-meta]');
  if (!island?.textContent) return null;
  const record = JSON.parse(island.textContent);
  return record?.version === 1 ? record : null;
}

const blank = (value: Value) => value === null || value === ''
  || (Array.isArray(value) && value.length === 0)
  || (typeof value === 'object' && !Array.isArray(value) && Object.keys(value).length === 0);

// Typst's canonical card anchor: "zk-node-" and the ID's UTF-8 bytes in hex.
const anchor = (id: string) => 'zk-node-'
  + [...new TextEncoder().encode(id)].map(byte => byte.toString(16).padStart(2, '0')).join('');

/** A note reference, marked exactly as Typst marks its note links. */
function noteLink(id: string, source: string): Node {
  const entry = entries.get(id);
  const span = document.createElement('span');
  if (!entry) {
    span.className = 'zk-unpublished';
    span.textContent = id;
    return span;
  }
  span.className = 'zk-link';
  span.dataset.zkSource = source;
  span.dataset.zkTarget = id;
  const link = document.createElement('a');
  link.href = new URL('#' + anchor(id), routeURL(entry)).href;
  link.textContent = entry.title;
  span.append(link);
  return span;
}

function joined(parts: Node[], separator: string): Node | null {
  if (parts.length === 0) return null;
  const fragment = document.createDocumentFragment();
  parts.forEach((part, i) => fragment.append(...(i ? [separator, part] : [part])));
  return fragment;
}

/** One value as DOM; `source` owns any note links. Blank values render nothing. */
export function renderValue(value: Value, source: string): Node | null {
  if (blank(value)) return null;
  if (typeof value === 'boolean') return document.createTextNode(value ? 'yes' : 'no');
  if (typeof value !== 'object' || value === null) return document.createTextNode(String(value));
  if (Array.isArray(value)) {
    return joined(value.map(item => renderValue(item, source)).filter((it): it is Node => !!it), ', ');
  }
  if (typeof value.$html === 'string') {
    // Published by our own build after typesetting; strings never take this path.
    const template = document.createElement('template');
    template.innerHTML = value.$html;
    return template.content;
  }
  if (typeof value.$node === 'string') return noteLink(value.$node, source);
  return joined(Object.entries(value).flatMap(([key, item]) => {
    const rendered = renderValue(item, source);
    if (!rendered) return [];
    const fragment = document.createDocumentFragment();
    fragment.append(key + ': ', rendered);
    return [fragment];
  }), '; ');
}

/** The default `about` view: metadata, then the size of the neighbourhood. */
export async function renderAbout(card: Element): Promise<HTMLElement | null> {
  const record = readMeta(card);
  if (!record) return null;
  await manifest;
  const list = document.createElement('dl');
  list.className = 'zk-about';
  const row = (term: string, value: Node | null) => {
    if (!value) return;
    const dt = document.createElement('dt');
    dt.textContent = term;
    const dd = document.createElement('dd');
    dd.append(value);
    list.append(dt, dd);
  };
  for (const [key, value] of Object.entries(record.metadata)) row(key, renderValue(value, record.id));
  for (const name of ['backlinks', 'links']) {
    row(name, document.createTextNode(String(record.relations[name]?.length ?? 0)));
  }
  return list;
}
