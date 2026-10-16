// Typst writes MathML for browsers together with its own stylesheet (sent in
// each document's <head>): operator names are zero-spaced <mo>, alignment
// lives in CSS classes. MathJax reads MathML attributes only, so each rule
// below restates one Typst convention in standard MathML.
//
// Every rule compensates for a specific Typst output, observed with Typst
// 0.15.1; test/standardize.test.mjs checks both that Typst still produces it
// and what the rule makes of it. When Typst changes, a failing precondition
// names the rule to revise or delete.
import { parse } from 'node-html-parser';

const cells = row => row.childNodes.filter(node => node.rawTagName === 'mtd');
const classesOf = element => (element.getAttribute('class') ?? '').split(/\s+/);

/**
 * @typedef {object} Rule
 * @property {string} name
 * @property {string} typst The Typst output this rule compensates for.
 * @property {(math: import('node-html-parser').HTMLElement) => void} apply
 */

/** @type {Rule} */
export const operatorNames = {
  name: 'operator-names',
  typst: '`op("Hom")` is `<mo form="prefix" lspace="0em" rspace="0em">Hom</mo>`, '
    + 'which MathJax sets without the space after a preceding relation.',
  apply(math) {
    for (const mo of math.querySelectorAll('mo')) {
      if (mo.getAttribute('form') !== 'prefix' || !/^\p{L}[\p{L}\p{N}]*$/u.test(mo.text)) continue;
      // As <mi>, an operator name takes TeX spacing (multi-letter: operator class).
      const variant = mo.text.length === 1 ? ' mathvariant="normal"' : '';
      mo.replaceWith(`<mi${variant}>${mo.text}</mi>`);
    }
  },
};

/** @type {Rule} */
export const operatorSpacing = {
  name: 'operator-spacing',
  typst: 'Operators carry explicit `lspace`/`rspace` (e.g. `lspace="0em"` on `∮`), '
    + 'which override MathJax\'s TeX spacing classes.',
  apply(math) {
    for (const mo of math.querySelectorAll('mo')) {
      mo.removeAttribute('lspace');
      mo.removeAttribute('rspace');
    }
  },
};

/** @type {Rule} */
export const breakAfterOperators = {
  name: 'break-after-operators',
  typst: 'No `linebreakstyle`: MathML breaks inline math before an operator; TeX breaks after it.',
  apply(math) {
    for (const mo of math.querySelectorAll('mo')) mo.setAttribute('linebreakstyle', 'after');
  },
};

/** @type {Rule} */
export const stretchyOverline = {
  name: 'stretchy-overline',
  typst: 'MathML export drops `overline`; the site rules restate it as an accent with '
    + 'U+203E, which Typst writes as the non-stretching combining overline U+0305.',
  apply(math) {
    for (const mo of math.querySelectorAll('mover > mo')) {
      if (mo.text !== '̅') continue;
      mo.set_content('‾');
      mo.setAttribute('stretchy', 'true');
    }
  },
};

/** @type {Rule} */
export const alignedColumns = {
  name: 'aligned-columns',
  typst: '`&` alignment is `<mtable class="aligned">`; CSS right-aligns odd and left-aligns '
    + 'even columns, with no padding.',
  apply(math) {
    for (const table of math.querySelectorAll('mtable')) {
      if (!classesOf(table).includes('aligned')) continue;
      const rows = table.querySelectorAll('mtr');
      const columns = Math.max(0, ...rows.map(row => cells(row).length));
      table.setAttribute('columnalign',
        Array.from({ length: columns }, (_, i) => (i % 2 ? 'left' : 'right')).join(' '));
      table.setAttribute('columnspacing', '0em');
      // As amsmath's `&={}`: a relation opening a right-hand column keeps its left space.
      for (const row of rows) {
        cells(row).forEach((cell, i) => {
          const first = cell.childNodes.find(node => node.rawTagName);
          if (i % 2 === 1 && first?.rawTagName === 'mo') cell.insertAdjacentHTML('afterbegin', '<mi></mi>');
        });
      }
    }
  },
};

/** @type {Rule} */
export const tableAlignment = {
  name: 'table-alignment',
  typst: '`cases` is `<mtable class="cases">` and `mat(align: ..)` is '
    + '`class="left-align"`/`"right-align"`; CSS aligns their cells.',
  apply(math) {
    for (const table of math.querySelectorAll('mtable')) {
      const classes = classesOf(table);
      if (classes.includes('cases')) {
        table.setAttribute('columnalign', 'left');
        table.setAttribute('columnspacing', '1em');
      } else if (classes.includes('left-align')) {
        table.setAttribute('columnalign', 'left');
      } else if (classes.includes('right-align')) {
        table.setAttribute('columnalign', 'right');
      }
    }
  },
};

/** @type {Rule} */
export const multilineEquations = {
  name: 'multiline-equations',
  typst: 'Lines of a display equation are `<mtable class="multiline-equation">`; CSS keeps '
    + 'display style in its cells and adds 0.5em between rows.',
  apply(math) {
    for (const table of math.querySelectorAll('mtable')) {
      if (!classesOf(table).includes('multiline-equation')) continue;
      table.setAttribute('displaystyle', 'true');
      table.setAttribute('rowspacing', '0.5em');
    }
  },
};

/** @type {Rule} */
export const literalCode = {
  name: 'literal-code',
  typst: 'Raw text (including a displayed function value) is HTML <code> inside '
    + 'MathML; MathJax requires a MathML text node instead.',
  apply(math) {
    for (const code of math.querySelectorAll('code')) {
      const text = code.text.replace(/[&<>]/g, char => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' }[char]));
      code.replaceWith('<mtext mathvariant="monospace">' + text + '</mtext>');
    }
  },
};

/** In order: operator names must become <mi> before operators are respaced. */
export const rules = [
  literalCode,
  operatorNames,
  operatorSpacing,
  breakAfterOperators,
  stretchyOverline,
  alignedColumns,
  tableAlignment,
  multilineEquations,
];

/** Restate one Typst `<math>` element in standard MathML. */
export function standardize(mathml, selected = rules) {
  const math = parse(mathml).querySelector('math');
  for (const rule of selected) rule.apply(math);
  return math.toString();
}
