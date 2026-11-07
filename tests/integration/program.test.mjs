// Declarative components (LeanReact.Program): the compiled values round-trip through the ABI.
import test from 'node:test';
import assert from 'node:assert/strict';

const program = await import('../../examples/generated/smoke.mjs');
const { ctor, unit } = await import('../../engine/adapters/leanjs-react.mjs');
const fields = value => value.fields;
const list = value => { const out = []; while (value.tag === 'List.cons') { out.push(value.fields[0]); value = value.fields[1]; } return out; };
const component = value => { const [init, update, view, subscriptions, propsChanged] = fields(value); return { init, update, view, subscriptions, propsChanged }; };
const press = ctor('LeanReact.PressEvent.mk', [ctor('Bool.false'), ctor('Bool.false'), ctor('Bool.false'), ctor('Bool.false')]);

/** The message a click on the button labelled `label` sends. */
function click(view, label) {
  if (view.tag !== 'LeanReact.Program.Html.node') return undefined;
  const [, attrs, children] = fields(view);
  if (list(children).some(child => child.tag === 'LeanReact.Program.Html.text' && child.fields[0] === label)) {
    const attr = list(attrs).find(a => a.tag === 'LeanReact.Program.Attr.onPress');
    const result = attr.fields[0](press);
    return result.tag === 'Option.some' ? result.fields[0] : undefined;
  }
  for (const child of list(children)) { const found = click(child, label); if (found) return found; }
  return undefined;
}

test('a compiled Component runs init, update and view from JavaScript with exact bigint models', () => {
  const counter = component(program['Examples.Program.Counter']);
  const [model, cmd] = fields(counter.init(5n));
  assert.equal(model, 5n);
  assert.equal(cmd.tag, 'LeanReact.Program.Cmd.none');
  const view = counter.view(5n, model);
  assert.equal(view.tag, 'LeanReact.Program.Html.node');
  assert.equal(fields(view)[0], 'div');
  const big = click(view, 'Add 2^53 + 1');
  assert.deepEqual(big, program['Examples.Program.CounterMsg.add'](9007199254740993n));
  const [next] = fields(counter.update(5n, big, model));
  assert.equal(next, 9007199254740998n);
  assert.equal(counter.propsChanged.tag, 'Option.none');
});

test('a keyed list view carries keys and message decoders', () => {
  const todos = component(program['Examples.Program.Todos']);
  const [model] = fields(todos.init(unit));
  const view = todos.view(unit, model);
  const [, , children] = fields(view);
  const rows = list(fields(list(children)[1])[2]);
  assert.deepEqual(rows.map(row => row.tag), ['LeanReact.Program.Html.keyed', 'LeanReact.Program.Html.keyed']);
  assert.deepEqual(rows.map(row => row.fields[0]), ['1', '2']);
  const reversed = fields(todos.update(unit, click(view, 'Reverse'), model))[0];
  const again = list(fields(list(fields(todos.view(unit, reversed))[2])[1])[2]);
  assert.deepEqual(again.map(row => row.fields[0]), ['2', '1']);
});
