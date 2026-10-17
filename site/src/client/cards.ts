// Loading rendered cards from their canonical pages. Nothing here interprets
// knowledge semantics: Typst lays out each card as `section[data-zk-node]` and
// names the target note of every note link with `[data-zk-target]`.
import { loadPage, rememberPage } from './pages.mjs';

export type Entry = { id: string; route: string; title: string };

const manifestURL = new URL(
  document.querySelector<HTMLMetaElement>('meta[name="zk-manifest"]')!.content,
  location.href,
);
const siteRoot = new URL('.', manifestURL);

export const manifest: Promise<Entry[]> = fetch(manifestURL)
  .then(response => (response.ok ? response.json() : []))
  .catch(() => []);

export const entries = new Map<string, Entry>();
manifest.then(list => { for (const entry of list) entries.set(entry.id, entry); });

export const routeURL = (entry: Entry) => new URL(entry.route, siteRoot);

/**
 * The note link an event happened in, as Typst rendered it: an edge, with
 * both endpoints named, wherever the link has been moved to. Links without a
 * target (external, or to equations and other labels) are ordinary links.
 */
export function zkLink(target: EventTarget | null) {
  const element = target instanceof Element ? target.closest<HTMLElement>('[data-zk-target]') : null;
  const entry = element && entries.get(element.dataset.zkTarget ?? '');
  if (!element || !entry) return undefined;
  return { element, entry, source: element.dataset.zkSource };
}

/** Start loading a card's page before it is needed. */
export function prefetch(entry: Entry) {
  // Hover is an interactive request, even though it has no visible result yet.
  loadPage(routeURL(entry)).catch(() => {});
}

/** Prepare direct note destinations in the reading stack, including backmatter. */
export function initPrefetch(root: HTMLElement) {
  const home = root.querySelector<HTMLElement>(':scope > .zk-pane[data-page]');
  if (home?.dataset.page) rememberPage(new URL(home.dataset.page, siteRoot), document);
  const prepare = (within: Element) => {
    const links = [within, ...within.querySelectorAll<HTMLElement>('[data-zk-target], [data-zk-expand]')];
    for (const link of links) {
      const id = link.getAttribute('data-zk-target') ?? link.getAttribute('data-zk-expand');
      const entry = id && entries.get(id);
      if (entry) loadPage(routeURL(entry), true).catch(() => {});
    }
  };
  // Observe only the live reading surface. Detached prefetched pages and hover
  // templates never trigger recursive preloading of their own neighbours.
  manifest.then(() => {
    prepare(root);
    new MutationObserver(records => {
      for (const record of records) for (const node of record.addedNodes) {
        if (node instanceof Element && root.contains(node)) prepare(node);
      }
    }).observe(root, { childList: true, subtree: true });
  });
}

let instances = 0;
const idLists = ['for', 'headers', 'aria-labelledby', 'aria-describedby', 'aria-controls', 'aria-owns'];

/**
 * Move a fragment into this document: give its IDs a fresh namespace so
 * several instances of one card can coexist, keep in-fragment references
 * pointing at the renamed IDs, and make other links independent of the page
 * they were rendered on.
 */
export function relocate(root: Element, source: URL) {
  const prefix = `zk${++instances}-`;
  const all = [root, ...root.querySelectorAll('*')];
  const ids = new Set(all.map(el => el.id).filter(Boolean));
  const local = (value: string) => (ids.has(value) ? prefix + value : value);
  for (const el of all) {
    if (el.id) el.id = prefix + el.id;
    for (const attr of [...el.attributes]) {
      const { name, value } = attr;
      if (name === 'id') continue;
      if (idLists.includes(name)) {
        attr.value = value.split(/\s+/).map(local).join(' ');
      } else if (value.startsWith('#') && ids.has(value.slice(1))) {
        attr.value = '#' + prefix + value.slice(1);
      } else if (value.includes('url(#')) {
        attr.value = value.replace(/url\(#([^)]+)\)/g, (_, id) => `url(#${local(id)})`);
      } else if ((name === 'href' && el.localName === 'a') || name === 'src') {
        const url = new URL(value, source);
        attr.value = url.origin === location.origin
          ? url.pathname + url.search + url.hash
          : url.href;
      }
    }
  }
}

async function findCard(entry: Entry) {
  const page = await loadPage(routeURL(entry));
  const selector = `section[data-zk-node="${CSS.escape(entry.id)}"]`;
  // The remembered live page can contain expanded copies: prefer its original
  // top-level cards, whose pane alone carries the canonical data-page mark.
  const found = page.querySelector(`.zk-pane[data-page] > article > ${selector}`)
    ?? page.querySelector(selector);
  if (!found) throw new Error(`No card ${entry.id} in ${entry.route}`);
  return found;
}

/** A detached, relocated copy of a card. */
export async function fetchCard(entry: Entry) {
  const card = document.importNode(await findCard(entry), true) as HTMLElement;
  relocate(card, routeURL(entry));
  return card;
}

/**
 * A card's named view (`preview`, `expand`, `about`), as its layout declared
 * it: the content of a `[data-zk-view~=name]` template, or the element so
 * marked. An empty template means the card has no such view (null). A card
 * without any mark is shown by `fallback` when given, otherwise whole. The
 * result keeps the card's identity.
 */
export async function fetchView(
  entry: Entry,
  name: string,
  fallback?: (card: Element) => Promise<Node | null>,
) {
  const found = await findCard(entry);
  const marked = found.querySelector(`[data-zk-view~="${CSS.escape(name)}"]`);
  const made = !marked && fallback ? await fallback(found) : undefined;
  if (made === null) return null;
  const source = marked instanceof HTMLTemplateElement ? marked.content : marked ?? made ?? found;
  const view = document.createElement('section');
  view.setAttribute('data-zk-node', entry.id);
  if (source === found) view.append(...[...found.childNodes].map(node => document.importNode(node, true)));
  else view.append(document.importNode(source, true));
  if (!view.textContent?.trim() && !view.querySelector('img, svg, mjx-container')) return null;
  relocate(view, routeURL(entry));
  return view;
}
