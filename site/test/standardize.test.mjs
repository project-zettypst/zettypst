// Each rule is tested against real Typst output, in two steps:
//   precondition — Typst still emits the convention the rule compensates for;
//   result       — the rule restates it in standard MathML.
// A failing precondition after a Typst upgrade means that rule must be
// revised, or deleted if Typst now emits standard MathML itself.
import assert from 'node:assert/strict';
import { describe, test } from 'node:test';
import {
  alignedColumns, breakAfterOperators, multilineEquations, operatorNames,
  operatorSpacing, rules, standardize, stretchyOverline, tableAlignment, literalCode,
} from '../src/math/standardize.mjs';
import { createTypesetter } from '../src/math/typeset.mjs';
import { only, sources, typstHTML, typstMath } from './typst.mjs';

const [operatorName, integral, overline, macron, aligned, cases, left, right, lines, plain] = typstMath(`
$a = op("Hom") b$
$I |-> integral.cont z$
$overline(A B)$
$macron(x)$
$ x &= 1 \\ y + z &= 2 $
$ cases(x & "if" y, 0 & "else") $
$ mat(align: #left, 1, 22; 333, 4) $
$ mat(align: #right, 1, 22; 333, 4) $
$ a \\ b $
$a + b$
`);
const apply = (rule, mathml) => only(standardize(mathml, [rule]));

describe(literalCode.name, () => {
  const [literal] = typstMath('$ #raw("x < y & z") $');
  test('precondition: raw math text is an HTML code element', () => {
    assert.equal(only(literal).querySelector('code').text, 'x < y & z');
  });
  test('result: literal text remains escaped monospace MathML', async () => {
    const math = apply(literalCode, literal);
    assert.equal(math.querySelector('code'), null);
    const text = math.querySelector('mtext');
    assert.equal(text.text, 'x < y & z');
    assert.equal(text.getAttribute('mathvariant'), 'monospace');
    const typesetter = createTypesetter({ fontURL: 'fonts' });
    const output = await typesetter.typeset('<html><body>' + literal + '</body></html>');
    assert.match(output, /mjx-container/);
    assert.doesNotMatch(output, /mjx-merror/);
  });
});

test('text underline inside math is framed, not dropped as an HTML span', () => {
  const source = '$14#underline[6]$';
  const native = typstHTML(source);
  assert.equal(native.querySelector('math span')?.text, '6');
  const framed = typstHTML(`#import "${sources.site}": html-rules\n#show: html-rules\n${source}`);
  assert.equal(framed.querySelector('math'), null);
  assert.ok(framed.querySelector('svg'));
  assert.ok(framed.querySelector('svg [stroke]'), 'underline stroke remains in the SVG');
});

describe(operatorNames.name, () => {
  test('precondition: op() is a zero-spaced prefix <mo>', () => {
    const mo = only(operatorName).querySelectorAll('mo').find(it => it.text === 'Hom');
    assert.equal(mo?.getAttribute('form'), 'prefix');
    assert.equal(mo.getAttribute('lspace'), '0em');
  });
  test('result: an <mi> operator name', () => {
    const math = apply(operatorNames, operatorName);
    assert.equal(math.querySelectorAll('mi').filter(it => it.text === 'Hom').length, 1);
    assert.ok(!math.querySelectorAll('mo').some(it => it.text === 'Hom'));
  });
  test('result: symbols in prefix form stay operators', () => {
    assert.ok(apply(operatorNames, integral).querySelectorAll('mo').some(it => it.text === '∮'));
  });
});

describe(operatorSpacing.name, () => {
  test('precondition: operators carry explicit spacing', () => {
    const mo = only(integral).querySelectorAll('mo').find(it => it.text === '∮');
    assert.equal(mo?.getAttribute('lspace'), '0em');
  });
  test('result: no explicit spacing remains', () => {
    for (const mo of apply(operatorSpacing, integral).querySelectorAll('mo')) {
      assert.equal(mo.getAttribute('lspace'), undefined);
      assert.equal(mo.getAttribute('rspace'), undefined);
    }
  });
});

describe(breakAfterOperators.name, () => {
  test('precondition: no line-break style is given', () => {
    assert.ok(only(integral).querySelectorAll('mo').every(it => !it.hasAttribute('linebreakstyle')));
  });
  test('result: every operator breaks after itself', () => {
    const operators = apply(breakAfterOperators, integral).querySelectorAll('mo');
    assert.ok(operators.length > 0);
    assert.ok(operators.every(it => it.getAttribute('linebreakstyle') === 'after'));
  });
});

describe(stretchyOverline.name, () => {
  test('precondition: the site rules make overline a combining U+0305 accent', () => {
    const mo = only(overline).querySelector('mover > mo');
    assert.equal(mo?.text, '̅');
  });
  test('result: a stretchy U+203E overline', () => {
    const mo = apply(stretchyOverline, overline).querySelector('mover > mo');
    assert.equal(mo.text, '‾');
    assert.equal(mo.getAttribute('stretchy'), 'true');
  });
  test('result: macron stays a short accent', () => {
    assert.equal(apply(stretchyOverline, macron).querySelector('mover > mo').text, '̄');
  });
});

describe(alignedColumns.name, () => {
  test('precondition: `&` alignment is a CSS class', () => {
    const table = only(aligned).querySelector('mtable');
    assert.ok(table.classList.contains('aligned'));
    assert.equal(table.getAttribute('columnalign'), undefined);
  });
  test('result: alternating column alignment without gaps', () => {
    const table = apply(alignedColumns, aligned).querySelector('mtable');
    assert.equal(table.getAttribute('columnalign'), 'right left');
    assert.equal(table.getAttribute('columnspacing'), '0em');
  });
  test('result: a relation opening the right column follows an empty atom', () => {
    for (const row of apply(alignedColumns, aligned).querySelectorAll('mtr')) {
      const [, right] = row.querySelectorAll('mtd');
      assert.equal(right.firstChild.rawTagName, 'mi');
      assert.equal(right.firstChild.text, '');
    }
  });
});

describe(tableAlignment.name, () => {
  test('precondition: cases and mat(align:) are CSS classes', () => {
    assert.ok(only(cases).querySelector('mtable').classList.contains('cases'));
    assert.ok(only(left).querySelector('mtable').classList.contains('left-align'));
    assert.ok(only(right).querySelector('mtable').classList.contains('right-align'));
  });
  test('result: column alignment attributes', () => {
    const casesTable = apply(tableAlignment, cases).querySelector('mtable');
    assert.equal(casesTable.getAttribute('columnalign'), 'left');
    assert.equal(casesTable.getAttribute('columnspacing'), '1em');
    assert.equal(apply(tableAlignment, left).querySelector('mtable').getAttribute('columnalign'), 'left');
    assert.equal(apply(tableAlignment, right).querySelector('mtable').getAttribute('columnalign'), 'right');
  });
});

describe(multilineEquations.name, () => {
  test('precondition: lines are a CSS-styled table', () => {
    const table = only(lines).querySelector('mtable');
    assert.ok(table.classList.contains('multiline-equation'));
    assert.equal(table.getAttribute('displaystyle'), undefined);
  });
  test('result: display style and row spacing', () => {
    const table = apply(multilineEquations, lines).querySelector('mtable');
    assert.equal(table.getAttribute('displaystyle'), 'true');
    assert.equal(table.getAttribute('rowspacing'), '0.5em');
  });
});

describe('all rules', () => {
  test('plain math keeps its structure', () => {
    const math = only(standardize(plain));
    assert.deepEqual(math.childNodes.map(it => it.rawTagName), ['mi', 'mo', 'mi']);
  });
  test('MathJax typesets every standardized sample without errors', async () => {
    const typesetter = createTypesetter({ fontURL: 'mathjax' });
    const samples = [operatorName, integral, overline, macron, aligned, cases, left, right, lines, plain];
    const html = await typesetter.typeset(`<body>${samples.join('')}</body>`);
    assert.equal((html.match(/<mjx-container/g) ?? []).length, samples.length);
    assert.ok(!/merror|data-mjx-error/.test(html));
  });
  test('every rule is registered exactly once', async () => {
    const exported = Object.values(await import('../src/math/standardize.mjs'))
      .filter(value => typeof value === 'object' && typeof value?.apply === 'function');
    assert.equal(new Set(rules).size, rules.length);
    assert.deepEqual(new Set(exported), new Set(rules));
  });
});
