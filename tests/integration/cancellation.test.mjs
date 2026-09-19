import test from 'node:test';
import assert from 'node:assert/strict';
import { JSDOM } from 'jsdom';

const { window } = new JSDOM('<!doctype html><html><body></body></html>');
Object.assign(globalThis, { window, document: window.document, HTMLElement: window.HTMLElement,
  IS_REACT_ACT_ENVIRONMENT: true });
const React = await import('react');
const { createRoot } = await import('react-dom/client');
const { mountElement, ctor, configureRuntime, callFailure } = await import('../../engine/adapters/leanjs-react.mjs');
const { createTicketsService, createTicketsLoader } = await import('../../examples/adapters/tickets-service.mjs');
const { encodeSummary } = await import('../../examples/adapters/tickets-service.mjs');
const { CallFailure, operations } = await import('../../examples/adapters/tickets-client/operations.mjs');
const program = await import('../../examples/generated/tickets.mjs');
const seed = program['Examples.Tickets.initialTickets'];
const listIdentity = { namespace: 'leanreact.tickets', name: 'list', version: '1' };

/** A fetch double that records each request's signal and lets the test settle replies in any order. */
function fetchDouble() {
  const calls = [];
  const fetch = (url, init) => new Promise((resolve, reject) => {
    const call = { url, signal: init.signal, aborted: false, settled: false, resolve, reject };
    init.signal.addEventListener('abort', () => { call.aborted = true; reject(new Error('aborted')); });
    calls.push(call);
  });
  // The reply body is what the server would send: the generated output codec's wire form
  // (tagged nats, tagged options), not the adapter's JavaScript view of a summary.
  const reply = (call, tickets) => call.resolve(new Response(JSON.stringify({
    operation: listIdentity, tag: 'success', value: operations.list.output.encode(tickets.map(encodeSummary)),
  }), { status: 200, headers: { 'content-type': 'application/json' } }));
  return { fetch, calls, reply };
}
const titled = title => seed.map((ticket, index) => index ? ticket : ctor(ticket.tag, [
  ticket.fields[0], ticket.fields[1], ctor(ticket.fields[2].tag, [ctor('Examples.Tickets.Title.mk', [title]), ...ticket.fields[2].fields.slice(1)]),
]));

async function mounted(options) {
  const service = createTicketsService(options);
  const load = createTicketsLoader(options);
  const container = document.createElement('div');
  document.body.append(container);
  const root = createRoot(container);
  await React.act(() => root.render(mountElement(program['Examples.Tickets.Workspace'],
    ctor('Examples.Tickets.WorkspaceProps.mk', ['remote', service, load]))));
  return {
    container,
    reload: () => React.act(() => [...container.querySelectorAll('button')].find(button => button.textContent === 'Reload tickets').click()),
    close: async () => { await React.act(() => root.unmount()); container.remove(); },
  };
}

test('unmounting during an in-flight list call aborts the fetch through the resource signal', async () => {
  const double = fetchDouble();
  const f = await mounted({ fetch: double.fetch, baseURL: 'http://service.test' });
  assert.equal(double.calls.length, 1);
  assert.equal(double.calls[0].url, 'http://service.test/api/tickets/list');
  assert.equal(double.calls[0].signal.aborted, false);
  await f.close();
  assert.equal(double.calls[0].signal.aborted, true);
  assert.equal(double.calls[0].aborted, true);
});

test('rapid refresh ×5 aborts superseded requests; at most one completes and the last generation wins', async () => {
  const double = fetchDouble();
  const f = await mounted({ fetch: double.fetch, baseURL: 'http://service.test' });
  try {
    for (let i = 0; i < 5; i++) await f.reload();
    assert.equal(double.calls.length, 6);
    assert.deepEqual(double.calls.map(call => call.signal.aborted), [true, true, true, true, true, false]);
    // Settle in reverse order: the stale generations are already aborted, the live one paints.
    const completed = [];
    for (const [index, call] of [...double.calls.entries()].reverse()) {
      if (!call.signal.aborted) completed.push(index);
      await React.act(async () => { double.reply(call, titled(`Reply ${index}`)); await Promise.resolve(); });
    }
    assert.deepEqual(completed, [5]);
    assert.equal(f.container.querySelector('.card h3').textContent, 'Reply 5');
    assert.equal(f.container.querySelector('[role="alert"]'), null);
  } finally { await f.close(); }
});

test('a component matching on CallFailure renders distinct UI and the global hook fires once', async () => {
  const observed = [];
  configureRuntime({ onCallFailure: failure => { observed.push(failure.kind); return true; } });
  const respond = (status, body) => async () => new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });
  try {
    const unauthenticated = await mounted({ fetch: respond(401, { tag: 'unauthenticated' }), baseURL: 'http://service.test' });
    try {
      await React.act(async () => { await new Promise(resolve => setTimeout(resolve, 0)); });
      assert.equal(unauthenticated.container.querySelector('[role="alert"]').textContent, 'Sign in to load tickets.');
    } finally { await unauthenticated.close(); }
    const transport = await mounted({ fetch: async () => { throw new TypeError('network down'); }, baseURL: 'http://service.test' });
    try {
      await React.act(async () => { await new Promise(resolve => setTimeout(resolve, 0)); });
      assert.equal(transport.container.querySelector('[role="alert"]').textContent, 'Could not reach the ticket service. Try reloading.');
    } finally { await transport.close(); }
    const incompatible = await mounted({ fetch: respond(409, { tag: 'incompatible', expected: { ...listIdentity, version: '2' }, received: listIdentity }), baseURL: 'http://service.test' });
    try {
      await React.act(async () => { await new Promise(resolve => setTimeout(resolve, 0)); });
      assert.equal(incompatible.container.querySelector('[role="alert"]').textContent, 'The ticket service speaks version 2; reload to update.');
    } finally { await incompatible.close(); }
    assert.deepEqual(observed, ['unauthenticated', 'transport', 'incompatible']);
  } finally { configureRuntime({ onCallFailure: null }); }
});

test('the CallFailure bridge maps every host kind to the portable constructor and ignores other errors', () => {
  const wrapped = kind => callFailure(new CallFailure(kind, 'some.code', { expected: listIdentity, received: { ...listIdentity, version: '0' } }));
  assert.deepEqual(wrapped('unauthenticated'), ctor('LeanReact.ResourceFailure.call', [ctor('Contract.CallFailure.unauthenticated')]));
  assert.deepEqual(wrapped('forbidden').fields[0], ctor('Contract.CallFailure.forbidden'));
  assert.deepEqual(wrapped('cancelled').fields[0], ctor('Contract.CallFailure.cancelled'));
  assert.deepEqual(wrapped('decode').fields[0], ctor('Contract.CallFailure.decode', ['some.code']));
  assert.deepEqual(wrapped('protocol').fields[0], ctor('Contract.CallFailure.protocol', ['some.code']));
  assert.deepEqual(wrapped('transport').fields[0], ctor('Contract.CallFailure.transport', ['some.code']));
  assert.deepEqual(wrapped('incompatible').fields[0], ctor('Contract.CallFailure.incompatible', [
    ctor('Contract.OperationId.mk', ['leanreact.tickets', 'list', '1']), ctor('Contract.OperationId.mk', ['leanreact.tickets', 'list', '0']),
  ]));
  assert.equal(callFailure(new TypeError('plain')), null);
  assert.equal(callFailure(null), null);
});
