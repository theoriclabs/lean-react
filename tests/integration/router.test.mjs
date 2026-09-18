import test from 'node:test';
import assert from 'node:assert/strict';
import { JSDOM } from 'jsdom';

const { window } = new JSDOM('<!doctype html><html><body></body></html>', { url: 'http://localhost/router/' });
Object.assign(globalThis, { window, document: window.document, HTMLElement: window.HTMLElement, location: window.location,
  IS_REACT_ACT_ENVIRONMENT: true });
const React = await import('react');
const { createRoot } = await import('react-dom/client');
const { mountElement, ctor, router } = await import('../../engine/adapters/leanjs-react.mjs');
const { createMemoryHistory } = await import('../../engine/runtime/router.mjs');
const program = await import('../../examples/generated/smoke.mjs');
const App = program['Examples.Routing.App'];

async function mounted(initial) {
  const history = createMemoryHistory(initial);
  router.setHistory(history);
  const container = document.createElement('div');
  document.body.append(container);
  const root = createRoot(container);
  await React.act(() => root.render(mountElement(App)));
  const click = (element, init = {}) => {
    const event = new window.MouseEvent('click', { bubbles: true, cancelable: true, button: 0, ...init });
    let prevented;
    React.act(() => { element.dispatchEvent(event); prevented = event.defaultPrevented; });
    return prevented;
  };
  return {
    container, history, click,
    heading: () => container.querySelector('h2').textContent,
    location: () => container.querySelector('[data-testid="location"]').textContent,
    button: text => [...container.querySelectorAll('button')].find(button => button.textContent === text),
    close: async () => { await React.act(() => root.unmount()); container.remove(); },
  };
}

test('deep links decode through the codec, links navigate in place, and back/forward follow the history', async () => {
  const f = await mounted('/router/tickets/2');
  try {
    assert.equal(f.heading(), 'Ticket 2');
    assert.equal(f.container.querySelector('p').textContent, 'Write the release notes');
    assert.equal(f.location(), '/router/tickets/2');
    const home = f.container.querySelector('[data-testid="link-home"]');
    assert.equal(home.getAttribute('href'), '/router/');
    assert.equal(f.click(home), true);
    assert.equal(f.heading(), 'Tickets');
    assert.deepEqual(f.history.entries(), ['/router/tickets/2', '/router/']);
    assert.equal(f.click(f.container.querySelector('[data-testid="link-ticket-3"]')), true);
    assert.equal(f.heading(), 'Ticket 3');
    await React.act(() => f.history.back());
    assert.equal(f.heading(), 'Tickets');
    await React.act(() => f.history.forward());
    assert.equal(f.heading(), 'Ticket 3');
    await React.act(() => f.button('Back').click());
    assert.equal(f.heading(), 'Tickets');
    // Navigating to the current route adds no history entry.
    assert.equal(f.click(f.container.querySelector('[data-testid="link-home"]')), true);
    assert.deepEqual(f.history.entries(), ['/router/tickets/2', '/router/', '/router/tickets/3']);
    assert.equal(f.history.index(), 1);
  } finally { await f.close(); }
});

test('modified clicks and external anchors keep the browser default; replace rewrites the entry', async () => {
  const f = await mounted('/router/tickets/1');
  try {
    const home = f.container.querySelector('[data-testid="link-home"]');
    assert.equal(f.click(home, { metaKey: true }), false);
    assert.equal(f.click(home, { button: 1 }), false);
    assert.equal(f.heading(), 'Ticket 1');
    const external = [...f.container.querySelectorAll('a')].find(anchor => anchor.textContent === 'GitHub');
    assert.equal(external.getAttribute('href'), 'https://github.com/theoriclabs/lean-react');
    // The document listener runs after React's root listener: the runtime saw an unprevented click and left it alone.
    const swallow = event => event.preventDefault();
    document.addEventListener('click', swallow, { once: true });
    assert.equal(f.click(external), true);
    document.removeEventListener('click', swallow);
    assert.equal(f.heading(), 'Ticket 1');
    assert.deepEqual(f.history.entries(), ['/router/tickets/1']);
    await React.act(() => f.button('Replace with About').click());
    assert.equal(f.heading(), 'About');
    assert.deepEqual(f.history.entries(), ['/router/about']);
  } finally { await f.close(); }
});

test('an unknown path renders the notFound route with the raw location', async () => {
  const f = await mounted('/router/nowhere?x=1');
  try {
    assert.equal(f.heading(), 'Not found');
    assert.equal(f.container.querySelector('[role="alert"] p').textContent, 'No screen for /router/nowhere?x=1.');
    assert.equal(f.click(f.container.querySelector('[role="alert"] a')), true);
    assert.equal(f.heading(), 'Tickets');
  } finally { await f.close(); }
});

test('Query.parse/encode and the codec run through the host URL intrinsics', () => {
  const pairs = program['LeanReact.Query.parse']('?a=1&b=x%20y+z&c&d=e=f');
  assert.deepEqual(pairs.map(pair => pair.fields), [['a', '1'], ['b', 'x y z'], ['c', ''], ['d', 'e=f']]);
  assert.equal(program['LeanReact.Query.encode']([ctor('Prod.mk', ['a b', '1&2']), ctor('Prod.mk', ['ü', '~*'])]), 'a+b=1%262&%C3%BC=%7E*');
  const codec = program['Examples.Routing.codec'];
  assert.deepEqual(codec.fields[0]('/router/tickets/7?tab=x'), ctor('Option.some', [ctor('Examples.Routing.Route.ticket', [7n])]));
  assert.deepEqual(codec.fields[0]('/router/tickets/seven'), ctor('Option.none'));
  assert.equal(codec.fields[1](ctor('Examples.Routing.Route.ticket', [7n])), '/router/tickets/7');
  assert.throws(() => router.history().push('https://example.com/'), /same-origin/);
  assert.throws(() => createMemoryHistory('//evil'), /same-origin/);
});
