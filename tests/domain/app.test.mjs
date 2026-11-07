// DDD-LR-06: the post's pages, compiled with LeanJS and mounted as one `App` over the
// generated client for the post's `api` (decision-5 envelope, decision-15 wire values).
// Ports the mounted scenarios of browser.test.mjs to the endpoint surface: forms, `call`,
// `load`, routing, visibility rendering, logout invalidation and late replies.
import test from 'node:test';
import assert from 'node:assert/strict';
import {JSDOM} from 'jsdom';
import {action} from '../../engine/runtime/actions.mjs';
import {createContractInterpreter} from '../../engine/adapters/leanjs-contract.mjs';
const {window} = new JSDOM('<!doctype html><html><body></body></html>');
Object.assign(globalThis, {window, document: window.document, HTMLElement: window.HTMLElement, IS_REACT_ACT_ENVIRONMENT: true});
const React = await import('react');
const {createRoot} = await import('react-dom/client');
const {mountElement, ctor} = await import('../../engine/adapters/leanjs-react.mjs');
const program = await import('./generated/domain.mjs');
const generated = await import('./generated/post/operations.mjs');
const unit = ctor('PUnit.unit');
const none = ctor('Option.none');
const some = value => ctor('Option.some', [value]);
const deferred = () => {let resolve; const promise = new Promise(done => {resolve=done;}); return {promise, resolve};};
const settle = () => React.act(async () => {for (let i = 0; i < 5; i++) await new Promise(r => setTimeout(r, 0));});

function server(handler) {
  const requests = [];
  const client = generated.createClient({fetch: async (url, init) => {
    const request = {url, method: init.method, body: init.body ? JSON.parse(init.body) : null};
    requests.push(request);
    const {status = 200, body} = await handler(request, requests.length);
    return {status, text: async () => JSON.stringify(body)};
  }});
  return {requests, interpreter: createContractInterpreter({program, client})};
}
const ok = value => ({body: {ok: value}});
const domainError = tag => ({status: 422, body: {error: tag}});
const page = (guests, title = 'Picnic') => ok({title, description: '', date: '2026-10-17T19:00:00Z', guests});
const visible = names => ({tag: 'visible', value: {guests: names.map(name => ({name}))}});
const hidden = {tag: 'hidden', value: null};

function shell(events, generation = 0n) {
  return program['PostViews.shellProps'](generation, action(() => generation),
    error => action(() => {events.push(['framework', error.tag]); return unit;}),
    path => action(() => {events.push(['navigate', path]); return unit;}),
    action(() => {events.push(['authenticated']); return unit;}));
}
async function mountApp(srv, {location, actor = none, events = [], generation = 0n}) {
  const descriptor = program['PostViews.appComponent'](srv.interpreter);
  const element = props => mountElement(descriptor, program['PostViews.appProps'](shell(events, props.generation ?? generation), props.location ?? location, props.actor ?? actor));
  const container = document.createElement('div'); document.body.append(container);
  const root = createRoot(container);
  await React.act(() => root.render(element({})));
  return {container, events,
    render: async props => React.act(() => root.render(element(props))),
    close: async () => {await React.act(() => root.unmount()); container.remove();}};
}
const setInput = async (container, name, value) => {
  const input = container.querySelector(`[name="${name}"]`); assert.ok(input, name);
  const prototype = input.tagName === 'SELECT' ? window.HTMLSelectElement.prototype : window.HTMLInputElement.prototype;
  await React.act(() => {Object.getOwnPropertyDescriptor(prototype, 'value').set.call(input, value); input.dispatchEvent(new window.Event('change', {bubbles: true})); input.dispatchEvent(new window.Event('input', {bubbles: true}));});
};
const submit = async container => {await React.act(() => container.querySelector('form').dispatchEvent(new window.Event('submit', {bubbles: true, cancelable: true}))); await settle();};
const press = async (container, label) => {
  const button = [...container.querySelectorAll('button')].find(b => b.textContent === label); assert.ok(button, label);
  await React.act(() => button.dispatchEvent(new window.MouseEvent('click', {bubbles: true}))); await settle();
};

test('routes: pages by path, a typed path parameter, and not-found for a bad one', async () => {
  const srv = server(async () => page(visible([])));
  const app = await mountApp(srv, {location: '/sign-up'});
  try {
    assert.deepEqual([...app.container.querySelectorAll('input')].map(i => i.name), ['name', 'email', 'password']);
    await app.render({location: '/nowhere'});
    assert.match(app.container.textContent, /Page not found/);
    await app.render({location: '/parties/seven'});
    assert.match(app.container.textContent, /Page not found/, 'a non-reference segment is not a party page');
    await app.render({location: '/parties/7'}); await settle();
    assert.equal(srv.requests.at(-1).url, '/parties/7');
    assert.equal(srv.requests.at(-1).method, 'GET');
  } finally {await app.close();}
});

test('sign-up: emailTaken binds the email field; success marks authentication, then navigates', async () => {
  let reply = domainError('emailTaken');
  const srv = server(async () => reply);
  const app = await mountApp(srv, {location: '/sign-up'});
  try {
    await setInput(app.container, 'name', 'Asha');
    await setInput(app.container, 'email', 'asha@example.com');
    await setInput(app.container, 'password', 'correct horse battery');
    await submit(app.container);
    assert.equal(srv.requests[0].url, '/sign-up');
    assert.deepEqual(srv.requests[0].body, {name: 'Asha', email: 'asha@example.com', password: 'correct horse battery'});
    assert.match(app.container.textContent, /email: This email already has an account\. Sign in instead\?/);
    assert.deepEqual(app.events, []);
    assert.equal(app.container.querySelector('[name="email"]').value, 'asha@example.com', 'drafts survive the error');
    reply = ok(7);
    await submit(app.container);
    assert.deepEqual(app.events, [['authenticated'], ['navigate', '/']]);
  } finally {await app.close();}
});

test('sign-in: wrongEmailOrPassword is a notice, with no authentication or navigation', async () => {
  const srv = server(async () => domainError('wrongEmailOrPassword'));
  const app = await mountApp(srv, {location: '/sign-in'});
  try {
    await setInput(app.container, 'email', 'asha@example.com');
    await setInput(app.container, 'password', 'not the password');
    await submit(app.container);
    assert.match(app.container.textContent, /Wrong email or password\./);
    assert.deepEqual(app.events, []);
  } finally {await app.close();}
});

test('host: dateInPast binds the date field; success navigates to the new party by reference', async () => {
  let reply = domainError('dateInPast');
  const srv = server(async () => reply);
  const app = await mountApp(srv, {location: '/parties/new', actor: some('1')});
  try {
    await setInput(app.container, 'title', 'Picnic');
    await setInput(app.container, 'date', '2026-10-17T19:00:00');
    await setInput(app.container, 'guestList', 'everyone');
    await submit(app.container);
    assert.equal(srv.requests.length, 1);
    assert.equal(srv.requests[0].body.date, '2026-10-17T19:00:00Z');
    assert.ok(!Object.hasOwn(srv.requests[0].body, 'me'), 'the actor is never an editor or a body field');
    assert.match(app.container.textContent, /date: Pick a time in the future\./);
    reply = ok(12);
    await submit(app.container);
    assert.deepEqual(app.events.at(-1), ['navigate', '/parties/12']);
  } finally {await app.close();}
});

test('party page: load renders the visibility rows (visible, empty, hidden) from real wire values', async () => {
  for (const [guests, expect] of [[visible(['Ben', 'Cara']), /BenCara/], [visible([]), null], [hidden, /The host is keeping the guest list private\./]]) {
    const srv = server(async () => page(guests));
    const app = await mountApp(srv, {location: '/parties/1', actor: some('2')});
    try {
      await settle();
      assert.match(app.container.textContent, /Picnic/);
      assert.match(app.container.textContent, /2026-10-17 19:00 UTC/);
      if (expect) assert.match(app.container.textContent, expect);
      else { assert.ok(app.container.querySelector('ul')); assert.ok(!/private/.test(app.container.textContent)); }
    } finally {await app.close();}
  }
});

test('rsvp call: a domain error is a notice; success reloads the page data', async () => {
  let rsvpReply = domainError('alreadyStarted'), pages = 0;
  const srv = server(async request => {
    if (request.url.endsWith('/rsvp')) return rsvpReply;
    pages++;
    return page(visible(pages === 1 ? ['Ben'] : ['Ben', 'Cara']));
  });
  const app = await mountApp(srv, {location: '/parties/3', actor: some('5')});
  try {
    await settle();
    await press(app.container, "I'm going");
    const rsvp = srv.requests.find(r => r.url === '/parties/3/rsvp');
    assert.ok(rsvp, 'the call binds the page reference into the path');
    assert.deepEqual(rsvp.body, {});
    assert.match(app.container.textContent, /This party has already started\./);
    assert.equal(pages, 1, 'a domain error does not reload');
    rsvpReply = ok(null);
    await press(app.container, "I'm going");
    assert.equal(pages, 2, 'a successful command reloads the page');
    assert.match(app.container.textContent, /BenCara/);
  } finally {await app.close();}
});

test('cancel call: success navigates; a non-host gets the notice', async () => {
  let reply = domainError('notHost');
  const srv = server(async request => request.url.endsWith('/cancel') ? reply : page(hidden));
  const app = await mountApp(srv, {location: '/parties/4', actor: some('5')});
  try {
    await settle();
    await press(app.container, 'Cancel party');
    assert.match(app.container.textContent, /Only the host can cancel this party\./);
    reply = ok(null);
    await press(app.container, 'Cancel party');
    assert.deepEqual(app.events.at(-1), ['navigate', '/parties/new']);
  } finally {await app.close();}
});

test('logout invalidation: an actor change drops the visible list at once; a late reply for the old actor never shows', async () => {
  const late = deferred(); let calls = 0;
  const srv = server(async () => {
    calls++;
    if (calls === 1) return page(visible(['Old Alice']));
    if (calls === 2) {await late.promise; return page(visible(['Stale Bob']));}
    return page(hidden);
  });
  const app = await mountApp(srv, {location: '/parties/1', actor: some('2')});
  try {
    await settle();
    assert.match(app.container.textContent, /Old Alice/);
    // A new auth generation for the same actor refetches; its reply is held back.
    await app.render({generation: 1n}); await settle();
    assert.ok(!app.container.textContent.includes('Old Alice'), 'the old value is dropped at once');
    // Sign out before the held reply arrives.
    await app.render({generation: 2n, actor: none}); await settle();
    assert.match(app.container.textContent, /The host is keeping the guest list private\./);
    await React.act(async () => {late.resolve(); await late.promise;}); await settle();
    assert.ok(!app.container.textContent.includes('Stale Bob'), 'a late reply for an older scope never shows');
    assert.match(app.container.textContent, /private/);
    assert.equal(calls, 3);
  } finally {await app.close();}
});

test('framework failures stay on the shared channel', async () => {
  const srv = server(async () => ({status: 401, body: {error: 'unauthorized'}}));
  const app = await mountApp(srv, {location: '/parties/1'});
  try {
    await settle();
    assert.deepEqual(app.events, [['framework', 'Contract.CallError.unauthenticated']]);
    assert.match(app.container.textContent, /Unable to load/);
  } finally {await app.close();}
});
