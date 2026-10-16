// Transient reading aids: hover previews and Forester-style in-place
// expansion of collapsed backmatter trees. Both act on note links only, as
// Typst marked them; a preview's links open in the stack, never nested.
import { entries, fetchView, manifest, zkLink } from './cards';
import { open } from './stack';

const hoverable = matchMedia('(hover: hover) and (pointer: fine)');

export function initPreview() {
  const popover = document.createElement('aside');
  popover.className = 'zk-preview';
  popover.hidden = true;
  document.body.append(popover);
  type Link = NonNullable<ReturnType<typeof zkLink>>;
  type Session = {
    link: Link;
    origin: HTMLElement;
    phase: 'waiting' | 'loading' | 'visible' | 'cancelled';
    showTimer?: number;
    leaveTimer?: number;
  };
  let session: Session | undefined;

  // Normalize DOM descendants to a semantic link before comparing boundaries.
  const paneLink = (target: EventTarget | null) =>
    target instanceof Element && target.closest('.zk-pane') ? zkLink(target) : undefined;
  const inPopover = (target: EventTarget | null) =>
    target instanceof Node && !popover.hidden && popover.contains(target);
  const clearTimers = (active: Session) => {
    clearTimeout(active.showTimer);
    clearTimeout(active.leaveTimer);
  };
  const end = () => {
    if (session) clearTimers(session);
    session = undefined;
    popover.hidden = true;
  };
  const cancel = () => {
    if (!session) return;
    clearTimers(session);
    // Cancellation belongs only to this visit, never to the destination card.
    session.phase = 'cancelled';
    popover.hidden = true;
  };
  const place = (link: HTMLElement) => {
    const box = link.getBoundingClientRect();
    const width = Math.min(popover.offsetWidth, innerWidth - 16);
    popover.style.left = `${Math.max(8, Math.min(box.left, innerWidth - width - 8))}px`;
    const below = innerHeight - box.bottom > popover.offsetHeight + 12 || box.top < innerHeight / 2;
    popover.style.top = below ? `${box.bottom + 6}px` : '';
    popover.style.bottom = below ? '' : `${innerHeight - box.top + 6}px`;
  };

  const begin = (link: Link) => {
    end();
    const active: Session = {
      link,
      origin: link.element.closest<HTMLElement>('.zk-pane')!,
      phase: 'waiting',
    };
    session = active;
    active.showTimer = window.setTimeout(async () => {
      active.phase = 'loading';
      try {
        // Self-links show metadata; other links show the target's preview.
        const view = link.source === link.entry.id ? 'about' : 'preview';
        const preview = await fetchView(link.entry, view);
        // Session identity, not link identity, owns the async result.
        if (session !== active || session.phase !== 'loading') return;
        if (!preview || !link.element.isConnected) { end(); return; }
        popover.replaceChildren(preview);
        active.phase = 'visible';
        popover.hidden = false;
        popover.scrollTop = 0;
        place(link.element);
      } catch (error) {
        if (session === active && session.phase === 'loading') end();
        console.error(error);
      }
    }, 350);
  };

  document.addEventListener('mouseover', event => {
    if (!hoverable.matches) return;
    if (inPopover(event.target)) {
      if (session) clearTimeout(session.leaveTimer);
      return; // Preview links never start nested previews.
    }
    const link = paneLink(event.target);
    if (!link) return;
    if (session?.link.element === link.element) {
      clearTimeout(session.leaveTimer);
      return;
    }
    begin(link);
  });
  document.addEventListener('mouseout', event => {
    const active = session;
    if (!active) return;
    const fromLink = paneLink(event.target)?.element === active.link.element;
    if (!fromLink && !inPopover(event.target)) return;
    if (paneLink(event.relatedTarget)?.element === active.link.element || inPopover(event.relatedTarget)) return;
    // Only a visible preview needs a grace period to cross the gap into it.
    // Waiting/loading/cancelled visits end immediately on semantic exit.
    if (active.phase !== 'visible') { end(); return; }
    clearTimeout(active.leaveTimer);
    active.leaveTimer = window.setTimeout(() => {
      if (session === active) end();
    }, 180);
  });
  // A note link in the preview continues the reading path from the source pane.
  popover.addEventListener('click', event => {
    const found = zkLink(event.target);
    const origin = session?.origin;
    // Closing the surface under the pointer ends this visit altogether.
    end();
    if (!found || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
    event.preventDefault();
    open(found.entry, origin);
  });
  document.addEventListener('click', event => {
    if (!session || inPopover(event.target)) return;
    const onSource = paneLink(event.target)?.element === session.link.element;
    if (onSource) cancel();
    else end();
  }, true);
  // Losing the pointer context ends the visit, including click suppression.
  window.addEventListener('blur', end);
  document.addEventListener('visibilitychange', () => { if (document.hidden) end(); });
  hoverable.addEventListener('change', () => { if (!hoverable.matches) end(); });
}

// A collapsed tree names its card in `data-zk-expand`.
export function initExpansion() {
  document.addEventListener('toggle', async event => {
    const details = event.target as HTMLDetailsElement;
    if (!details.open || !details.matches('details[data-zk-expand]') || details.dataset.loaded) return;
    details.dataset.loaded = 'loading';
    await manifest;
    const entry = entries.get(details.dataset.zkExpand ?? '');
    try {
      if (!entry) throw new Error(`Unknown card ${details.dataset.zkExpand}`);
      const view = await fetchView(entry, 'expand');
      const main = document.createElement('div');
      main.className = 'mainmatter';
      // This tree already has its summary, and a <details> holds only one:
      // a <details> view contributes its content without its own summary.
      for (const node of [...(view?.childNodes ?? [])]) {
        if (node instanceof HTMLDetailsElement) {
          main.append(...[...node.childNodes].filter(child => !(child instanceof HTMLElement && child.localName === 'summary')));
        } else {
          main.append(node);
        }
      }
      details.append(main);
      details.dataset.loaded = 'true';
    } catch (error) {
      delete details.dataset.loaded;
      console.error('Could not expand tree', error);
    }
  }, true);
}
