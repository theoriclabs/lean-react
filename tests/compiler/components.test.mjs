// LR-14/P0: exercise real LeanJS output in the DOM. This small walker is a probe,
// not the public Program runtime (atomic dispatch, commands and lifecycle are P2/P3).
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { JSDOM } from 'jsdom';
import * as program from './components-generated.mjs';
import { operations } from './components-client-generated/operations.mjs';
import { parseJson } from '#leancontract/Fetch.mjs';

const { window } = new JSDOM('<!doctype html><html><body></body></html>');
Object.assign(globalThis, { window, document: window.document, HTMLElement: window.HTMLElement,
  IS_REACT_ACT_ENVIRONMENT: true });
const React = await import('react');
const { createRoot } = await import('react-dom/client');
const f = name => program[`ComponentSpike.${name}`];
const ctor = (tag, fields = []) => ({ tag, fields });
const message = (tag, value) => ctor(`ComponentSpike.Msg.${tag}`, [value]);
const model = (count, title) => ctor('ComponentSpike.Model.mk', [count, title]);
const list = value => {
  const items = [];
  while (value.tag === 'List.cons') { items.push(value.fields[0]); value = value.fields[1]; }
  assert.equal(value.tag, 'List.nil');
  return items;
};

function walk(html, dispatch = () => {}, stats = { nodes: 0, depth: 0 }, depth = 1) {
  stats.nodes++;
  stats.depth = Math.max(stats.depth, depth);
  switch (html.tag) {
    case 'ComponentSpike.Html.none': return null;
    case 'ComponentSpike.Html.text': return html.fields[0];
    case 'ComponentSpike.Html.embed': {
      const [, , , component, props] = html.fields[0].fields;
      const [init, , view] = component.fields;
      return React.createElement('output', null, view(init(props)));
    }
    case 'ComponentSpike.Html.node': {
      const [tag, attributes, children] = html.fields;
      const props = {};
      for (const attribute of list(attributes)) {
        if (attribute.tag === 'ComponentSpike.Attr.attr') {
          const [name, value] = attribute.fields;
          props[name === 'value' ? 'defaultValue' : name] = value;
        } else {
          assert.equal(attribute.tag, 'ComponentSpike.Attr.on');
          const [event, decode] = attribute.fields;
          props[{ click: 'onClick', input: 'onInput' }[event]] = event => {
            const decoded = decode(event.currentTarget.value ?? '');
            if (decoded.tag === 'Option.some') dispatch(decoded.fields[0]);
            else assert.equal(decoded.tag, 'Option.none');
          };
        }
      }
      return React.createElement(tag, props,
        ...list(children).map(child => walk(child, dispatch, stats, depth + 1)));
    }
    default: assert.fail(`Unknown Html constructor ${html.tag}`);
  }
}

async function mount(element) {
  const container = document.createElement('div');
  document.body.append(container);
  const root = createRoot(container);
  await React.act(() => root.render(element));
  return { container, close: async () => {
    await React.act(() => root.unmount()); container.remove();
  } };
}
const input = async (element, value) => React.act(() => {
  Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set.call(element, value);
  element.dispatchEvent(new window.Event('input', { bubbles: true }));
});
const click = async element => React.act(() => element.dispatchEvent(new window.MouseEvent('click', { bubbles: true })));

test('P0 #1: a nested List-based Html value becomes the expected DOM', async () => {
  const html = f('view')('nested:');
  assert.equal(html.tag, 'ComponentSpike.Html.node');
  assert.equal(list(html.fields[2]).length, 3);
  const mounted = await mount(walk(html));
  try {
    assert.equal(mounted.container.querySelector('section').getAttribute('aria-label'), 'Component spike');
    assert.equal(mounted.container.querySelector('button').textContent, 'nested: click');
    assert.equal(mounted.container.querySelectorAll('input').length, 1);
  } finally { await mounted.close(); }
});

test('P0 #2: structural Html.map maps messages inside nested event closures', async () => {
  const received = [];
  const mounted = await mount(walk(f('mappedView'), msg => received.push(msg)));
  try {
    await click(mounted.container.querySelector('button'));
    await input(mounted.container.querySelector('input'), 'λ');
    assert.deepEqual(received, ['clicked:7', 'typed:nested:λ']);
  } finally { await mounted.close(); }
});

test('P0 #3: closures stored in attributes retain captures and filter none', async () => {
  const received = [];
  const mounted = await mount(walk(f('view')('capture:'), msg => received.push(msg)));
  try {
    await input(mounted.container.querySelector('input'), '🧪');
    await input(mounted.container.querySelector('input'), '');
    await click(mounted.container.querySelector('button'));
    assert.deepEqual(received, [message('typed', 'capture:🧪'), message('clicked', 7n)]);
  } finally { await mounted.close(); }
});

test('P0 #4: the host-erased child fallback retains distinct models and messages', async () => {
  const report = JSON.parse(readFileSync(new URL('./components-embed-generated.json', import.meta.url), 'utf8'));
  assert.equal(report.status, 'kernel-rejected');
  assert.equal(report.fallback, 'host-erased-child');
  const count = f('counterChild'), text = f('textChild');
  assert.equal(count.tag, 'ComponentSpike.Embed.mk');
  assert.deepEqual(count.fields.slice(0, 3), [null, null, null]);
  assert.deepEqual(text.fields.slice(0, 3), [null, null, null]);
  const run = (child, msg) => {
    const [, , , component, props, toParent] = child.fields;
    const [init, update, view] = component.fields;
    return { label: view(update(msg, init(props))), parent: toParent(msg) };
  };
  const a = run(count, 2n), b = run(text, 'value');
  assert.equal(f('embeddedNat'), 'count:9007199254740993');
  assert.equal(f('embeddedText'), 'child:');
  assert.equal(a.label, 'count:9007199254740995');
  assert.equal(b.label, 'child:value');
  assert.deepEqual(a.parent, ctor('Option.some', [message('clicked', 2n)]));
  assert.deepEqual(b.parent, ctor('Option.some', [message('typed', 'value')]));
  const mapped = list(f('mappedEmbeddedView').fields[2]);
  const mappedCount = mapped[0].fields[0], mappedText = mapped[1].fields[0];
  assert.deepEqual(run(mappedCount, 3n).parent, ctor('Option.some', ['child-click:3']));
  assert.deepEqual(run(mappedText, 'mapped').parent, ctor('Option.some', ['child-text:mapped']));
  const mounted = await mount(walk(f('embeddedView')));
  try {
    assert.deepEqual([...mounted.container.querySelectorAll('output')].map(node => node.textContent),
      ['count:9007199254740993', 'child:']);
  }
  finally { await mounted.close(); }

  // The real child view returns Html ChildMsg. Its bundle stays outside the
  // recursive Html type, and this probe host dispatches its own messages.
  const [, , , component, props, toParent] = f('recursiveChild').fields;
  const [init, update, view] = component.fields;
  let current = init(props);
  const received = [];
  const container = document.createElement('div'); document.body.append(container);
  const root = createRoot(container);
  const render = () => root.render(walk(view(current), msg => {
    current = update(msg, current);
    received.push(toParent(msg));
    render();
  }));
  try {
    await React.act(render);
    assert.equal(container.textContent, 'recursive:9007199254740993');
    await click(container.querySelector('button'));
    assert.equal(container.textContent, 'recursive:9007199254740995');
    assert.deepEqual(received, [ctor('Option.some', [message('clicked', 2n)])]);
  } finally { await React.act(() => root.unmount()); container.remove(); }
});

test('P0 #5: update returns Model × Cmd with a working captured continuation', async () => {
  const before = model(9007199254740993n, 'before');
  const pair = f('update')(message('clicked', 2n), before);
  assert.equal(pair.tag, 'Prod.mk');
  const [next, command] = pair.fields;
  assert.deepEqual(next, model(9007199254740995n, 'before'));
  assert.deepEqual(before, model(9007199254740993n, 'before'));
  assert.equal(command.tag, 'ComponentSpike.Cmd.batch');
  const [timer, request] = list(command.fields[0]);
  assert.deepEqual(timer, ctor('ComponentSpike.Cmd.after', [10n, message('typed', 'committed')]));
  assert.equal(request.tag, 'ComponentSpike.Cmd.request');
  assert.equal(request.fields[0], 9007199254740995n);
  const answer = request.fields[1](42n);
  assert.deepEqual(answer, message('typed', 'before:42'));
  const [finished, none] = f('update')(answer, next).fields;
  assert.deepEqual(finished, model(9007199254740995n, 'before:42'));
  assert.equal(none.tag, 'ComponentSpike.Cmd.none');
  const mounted = await mount(React.createElement('output', null, finished.fields[1]));
  try { assert.equal(mounted.container.textContent, 'before:42'); }
  finally { await mounted.close(); }
});

test('P0 #6: FromJson rejection is recorded and the generated-codec fallback works', async () => {
  const report = JSON.parse(readFileSync(new URL('./components-json-generated.json', import.meta.url), 'utf8'));
  assert.equal(report.status, 'rejected');
  assert.equal(report.fallback, 'generated-codecs');
  assert.match(report.diagnostic, /ComponentSpike\.decodePayload ->/);
  assert.match(report.diagnostic, /unsupported native extern operation/);
  assert.match(report.diagnostic, /Lean\.Name\.beq/);
  const wire = parseJson(readFileSync(new URL('./components-native-generated.json', import.meta.url), 'utf8'));
  const codec = operations.payload.output;
  const value = codec.decode(wire);
  assert.deepEqual(value, { title: 'λ🧪', count: 2n ** 128n + 9007199254740993n, enabled: true });
  assert.deepEqual(codec.encode(value), wire);
  assert.throws(() => codec.decode({ ...wire, enabled: 'true' }), /decode/);
  assert.throws(() => codec.decode({ title: wire.title, enabled: true }), /decode/);
  assert.throws(() => codec.decode({ ...wire, extra: true }), /decode/);
  const mounted = await mount(React.createElement('output', null, `${value.title}:${value.count}`));
  try { assert.equal(mounted.container.textContent, `λ🧪:${value.count}`); }
  finally { await mounted.close(); }
});

test('P0 #7: a 64-square view and a 128-level path render without a flat-tree fallback', async t => {
  const stats = { nodes: 0, depth: 0 };
  const started = performance.now();
  const tree = walk(f('board'), () => {}, stats);
  const walked = performance.now();
  const mounted = await mount(tree);
  try {
    assert.equal(mounted.container.querySelectorAll('[role="gridcell"]').length, 64);
    assert.equal(mounted.container.querySelector('[data-square="63"]').textContent, '63');
    assert.deepEqual(stats, { nodes: 193, depth: 4 });
    t.diagnostic(`64 squares: walk ${(walked - started).toFixed(2)} ms, walk + jsdom commit ${(performance.now() - started).toFixed(2)} ms`);
  } finally { await mounted.close(); }
  const deepStats = { nodes: 0, depth: 0 };
  const nested = await mount(walk(f('deep')(128n), () => {}, deepStats));
  try {
    assert.equal(nested.container.textContent, 'bottom');
    assert.deepEqual(deepStats, { nodes: 129, depth: 129 });
  } finally { await nested.close(); }
});
