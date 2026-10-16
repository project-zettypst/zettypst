import { initPrefetch } from './cards';
import { initPalette } from './palette';
import { initExpansion, initPreview } from './reading';
import { initStack } from './stack';

initPrefetch(document.querySelector<HTMLElement>('.zk-stack')!);
initStack();
initExpansion();
initPreview();
initPalette();
