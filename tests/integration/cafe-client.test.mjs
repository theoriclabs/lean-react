import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { build } from 'esbuild';
import { JSDOM } from 'jsdom';
import { createAuthClient } from '../../engine/LeanApp/AuthClient.mjs';
import {
  createCafeClient, errorMessage, formatMoney, INITIAL_CONFIGURATION, parseConfiguration,
  parsePreview, parseRecipe, parseRecipes,
} from '../../examples/cafe/client.mjs';

const configuration = () => ({ ...INITIAL_CONFIGURATION });
const recipe = (id = 'recipe-1', overrides = {}) => ({ id, name: 'Slow Sunday', configuration: configuration(), priceMinor: '475', ...overrides });
const session = (username = 'alice') => ({ user: { username, actor: `actor:${username}`, tenant: 'cafe', generation: '9007199254740993' }, csrf: 'a'.repeat(64) });
const response = (value, status = 200) => ({ ok: status >= 200 && status < 300, status, json: async () => value });
const success = (init, value) => response({ tag: 'success', operation: JSON.parse(init.body).operation, value });
const deferred = () => { let resolve; const promise = new Promise(done => { resolve = done; }); return { resolve, promise }; };
const tick = () => new Promise(resolve => setImmediate(resolve));
const code = expected => error => error.code === expected && error.message === expected;

async function setup(handler) {
  const calls = [];
  const auth = createAuthClient({ fetch: async (path, init) => {
    calls.push({ path, ...init });
    if (path === '/auth/session') return response(session());
    if (path === '/auth/logout') return response({ ok: true });
    if (path === '/auth/login') return response(session('bobby'));
    return handler(path, init);
  } });
  const cafe = createCafeClient({ auth });
  await auth.restore();
  return { auth, cafe, calls };
}

test('cents formatting stays exact above Number.MAX_SAFE_INTEGER', () => {
  for (const [minor, expected] of [
    ['0', '$0.00'], ['1', '$0.01'], ['99', '$0.99'], ['100', '$1.00'], ['475', '$4.75'],
    ['9007199254740993', '$90,071,992,547,409.93'],
    ['123456789012345678901234567890', '$1,234,567,890,123,456,789,012,345,678.90'],
  ]) assert.equal(formatMoney(minor), expected);
  for (const invalid of [1, null, '', '01', '-1', '1.2', '1e3', ' 1', '1 '])
    assert.throws(() => formatMoney(invalid), code('cafe.protocol'));
});

test('wire parsing copies and freezes exact shapes without enforcing drink business rules', () => {
  const raw = recipe();
  const parsed = parseRecipe(raw);
  raw.name = 'Changed'; raw.configuration.milk = 'oat';
  assert.equal(parsed.name, 'Slow Sunday'); assert.equal(parsed.configuration.milk, 'whole');
  assert.ok(Object.isFrozen(parsed)); assert.ok(Object.isFrozen(parsed.configuration));
  assert.ok(Object.isFrozen(parseRecipes([recipe()])));
  // Admissibility belongs to Lean. A schema-valid draft must reach that model unchanged.
  const unusual = { ...configuration(), temperature: 'iced', size: 'small', decaf: true, shots: 'triple' };
  assert.deepEqual(parseConfiguration(unusual), unusual);
  for (const config of [null, [], {}, { ...configuration(), extra: true }, { ...configuration(), decaf: 'false' },
    { ...configuration(), milk: 'unknown' }, { ...configuration(), size: null }])
    assert.throws(() => parseConfiguration(config), code('cafe.protocol'));
  for (const value of [null, [], {}, { ...recipe(), extra: true }, recipe('', {}), recipe('x', { name: 1 }),
    recipe('x', { priceMinor: 475 }), recipe('x', { priceMinor: '-1' }), recipe('x', { configuration: {} })])
    assert.throws(() => parseRecipe(value), code('cafe.protocol'));
  for (const value of [{ recipes: [] }, [recipe(), recipe()], [recipe(), null]])
    assert.throws(() => parseRecipes(value), code('cafe.protocol'));
});

test('preview parser accepts typed model results and rejects unchecked output', () => {
  assert.deepEqual(parsePreview({ ok: true, priceMinor: '9007199254740993' }), { ok: true, priceMinor: '9007199254740993' });
  for (const error of ['small_iced', 'decaf_triple', 'invalid_configuration', 'negative_price'])
    assert.deepEqual(parsePreview({ ok: false, error }), { ok: false, error });
  for (const value of [null, { ok: true, priceMinor: 475 }, { ok: true, priceMinor: '-1' },
    { ok: false, error: '<private detail>' }, { ok: true, priceMinor: '475', debug: 'private' }])
    assert.throws(() => parsePreview(value), code('cafe.protocol'));
});

test('recipe calls use the approved Contract identities, cookie auth, and server prices', async () => {
  let sentName;
  const { auth, cafe, calls } = await setup((path, init) => {
    if (path.endsWith('/list')) return success(init, [recipe()]);
    if (path.endsWith('/save')) {
      const input = JSON.parse(init.body).input; sentName = input.name;
      return success(init, recipe('new', { name: input.name, configuration: input.configuration, priceMinor: '9007199254740993' }));
    }
    return success(init, null);
  });
  let notifications = 0;
  const unsubscribe = cafe.subscribe(() => ++notifications);
  await cafe.load();
  const draft = { ...configuration(), milk: 'oat', temperature: 'iced' };
  const saved = await cafe.save('  ☕ Sunday  ', draft);
  assert.equal(sentName, '☕ Sunday');
  assert.equal(saved.priceMinor, '9007199254740993');
  assert.equal(cafe.getSnapshot().recipes[1].priceMinor, saved.priceMinor);
  await cafe.delete('recipe-1');
  assert.deepEqual(cafe.getSnapshot().recipes, [saved]);
  const apiCalls = calls.filter(call => call.path.startsWith('/api/'));
  assert.deepEqual(apiCalls.map(call => JSON.parse(call.body)), [
    { operation: { namespace: 'cafe', name: 'list', version: '1' }, kind: 'query', input: null },
    { operation: { namespace: 'cafe', name: 'save', version: '1' }, kind: 'command', input: { name: '☕ Sunday', configuration: draft } },
    { operation: { namespace: 'cafe', name: 'delete', version: '1' }, kind: 'command', input: 'recipe-1' },
  ]);
  for (const call of apiCalls) {
    assert.equal(call.credentials, 'same-origin'); assert.equal(call.method, 'POST');
    assert.equal(call.headers['X-CSRF-Token'], 'a'.repeat(64));
  }
  assert.equal(notifications, 6); unsubscribe();
  await auth.logout();
  await assert.rejects(cafe.load(), code('auth.required'));
  assert.equal(cafe.getSnapshot().recipes.length, 0);
  cafe.dispose();
});

test('malformed list, save and delete responses fail closed without changing the collection', async () => {
  let malformed = false;
  const { cafe } = await setup((path, init) => success(init,
    !malformed ? [recipe()] : path.endsWith('/list') ? [recipe('bad', { priceMinor: 5 })] : path.endsWith('/save') ? { name: 'bad' } : { ok: true }));
  await cafe.load(); malformed = true;
  for (const invoke of [() => cafe.load(), () => cafe.save('New cup', configuration()), () => cafe.delete('recipe-1')]) {
    await assert.rejects(invoke(), code('cafe.protocol'));
    assert.deepEqual(cafe.getSnapshot().recipes, [recipe()]);
    assert.equal(cafe.getSnapshot().busy, null);
    assert.equal(cafe.getSnapshot().error.code, 'cafe.protocol');
  }
  cafe.dispose();
});

test('Contract mismatch and collapsed domain errors expose safe text and never retry mutations', async () => {
  for (const reply of [
    response({ error: 'cafe.recipe_limit', detail: 'private SQL and secrets' }, 400),
    response({ tag: 'error', value: 'private payload' }),
    response({ tag: 'success', operation: { namespace: 'other', name: 'save', version: '1' }, value: recipe() }),
  ]) {
    const { cafe, calls } = await setup(() => reply);
    await assert.rejects(cafe.save('New cup', configuration()));
    await tick();
    assert.equal(calls.filter(call => call.path.endsWith('/save')).length, 1);
    assert.equal(cafe.getSnapshot().recipes.length, 0);
    assert.doesNotMatch(errorMessage(cafe.getSnapshot().error), /SQL|private|secrets|recipe_limit/);
    assert.doesNotMatch(JSON.stringify(cafe.getSnapshot()), /SQL|private|secrets|recipe_limit/);
    cafe.dispose();
  }
  for (const code of ['private', '__proto__', 'constructor', 'toString'])
    assert.equal(errorMessage({ code, message: 'private password' }), 'We could not complete that request. Check your details and try again.');
});

test('network failures are sanitized and overlapping mutations are not sent', async () => {
  const pending = deferred();
  const { cafe, calls } = await setup(() => pending.promise);
  const first = cafe.save('First', configuration());
  await assert.rejects(cafe.save('Second', configuration()), code('cafe.busy'));
  await assert.rejects(cafe.delete('recipe-1'), code('cafe.busy'));
  assert.equal(calls.filter(call => call.path.startsWith('/api/')).length, 1);
  pending.resolve(response({ error: 'unknown private detail' }, 500));
  await assert.rejects(first, code('cafe.failed'));
  cafe.dispose();
  const offline = await setup(() => { throw new Error('private hostname'); });
  await assert.rejects(offline.cafe.load(), code('auth.unavailable'));
  assert.doesNotMatch(errorMessage(offline.cafe.getSnapshot().error), /hostname/);
  offline.cafe.dispose();
});

test('logout and account replacement clear recipes immediately and suppress late requests', async () => {
  for (const transition of ['logout', 'login']) for (const action of ['list', 'save', 'delete']) for (const rejected of [false, true]) {
    const pending = deferred(); let delayed = false;
    const { auth, cafe } = await setup((path, init) => delayed ? pending.promise : success(init, [recipe()]));
    await cafe.load(); delayed = true;
    const operation = action === 'list' ? cafe.load() : action === 'save' ? cafe.save('New', configuration()) : cafe.delete('recipe-1');
    const stale = assert.rejects(operation, code('auth.stale'));
    const change = transition === 'logout' ? auth.logout() : auth.login('bobby', 'a long password');
    assert.deepEqual(cafe.getSnapshot().recipes, []);
    assert.equal(cafe.getSnapshot().busy, null);
    assert.equal(cafe.getSnapshot().loaded, false);
    await change;
    pending.resolve(rejected ? response({ error: 'auth.required' }, 401) : response({
      tag: 'success', operation: { namespace: 'cafe', name: action, version: '1' },
      value: action === 'list' ? [recipe('late')] : action === 'save' ? recipe('late') : null,
    }));
    await stale;
    assert.deepEqual(cafe.getSnapshot().recipes, []);
    assert.equal(cafe.getSnapshot().error, null);
    assert.equal(auth.getSnapshot().user?.username ?? null, transition === 'login' ? 'bobby' : null);
    cafe.dispose();
  }
});

test('the cafe boundary also suppresses stale results from a mock auth that does not filter them', async () => {
  let state = { epoch: 1, user: { username: 'alice' }, transitioning: false };
  let handler = async () => [recipe()];
  const subscribers = new Set();
  const auth = { getSnapshot: () => state, subscribe: fn => { subscribers.add(fn); return () => subscribers.delete(fn); }, call: (...args) => handler(...args) };
  const cafe = createCafeClient({ auth });
  await cafe.load();
  const old = deferred(); handler = () => old.promise;
  const oldLoad = cafe.load();
  const stale = assert.rejects(oldLoad, code('auth.stale'));
  state = { epoch: 2, user: { username: 'bobby' }, transitioning: false };
  for (const fn of subscribers) fn();
  assert.deepEqual(cafe.getSnapshot().recipes, []);
  const fresh = deferred(); handler = () => fresh.promise;
  const newLoad = cafe.load();
  old.resolve([recipe('old')]); await stale;
  assert.equal(cafe.getSnapshot().busy, 'list');
  fresh.resolve([recipe('new')]); await newLoad;
  assert.equal(cafe.getSnapshot().recipes[0].id, 'new');
  cafe.dispose(); assert.equal(subscribers.size, 0);
});

test('expired sessions clear previously loaded recipes before returning an error', async () => {
  let expired = false;
  const { auth, cafe } = await setup((path, init) => expired ? response({ error: 'auth.required' }, 401) : success(init, [recipe()]));
  await cafe.load(); expired = true;
  await assert.rejects(cafe.load(), code('auth.stale'));
  assert.equal(auth.getSnapshot().user, null);
  assert.deepEqual(cafe.getSnapshot().recipes, []);
  cafe.dispose();
});

// DOM checks use an explicit preview fixture. They never substitute JavaScript pricing for Lean.
let browserBundle;
async function appBundle() {
  browserBundle ??= build({
    entryPoints: [new URL('../../examples/cafe/main.mjs', import.meta.url).pathname],
    bundle: true, write: false, format: 'iife', platform: 'browser', target: 'es2022',
    loader: { '.mjs': 'jsx' }, define: { 'process.env.NODE_ENV': '"production"' },
    plugins: [{ name: 'preview-fixture', setup(builder) {
      builder.onResolve({ filter: /^\.\/domain\.mjs$/ }, () => ({ path: 'preview-fixture', namespace: 'test' }));
      builder.onLoad({ filter: /.*/, namespace: 'test' }, () => ({ contents: 'export const preview = configuration => window.__previewFixture(configuration);', loader: 'js' }));
    } }],
  }).then(result => result.outputFiles[0].text);
  return browserBundle;
}

async function waitFor(check) {
  for (let index = 0; index < 100; index++) {
    if (check()) return;
    await new Promise(resolve => setTimeout(resolve, 10));
  }
  assert.ok(check(), 'The expected UI state did not appear.');
}

async function mount(t, fetch, model = () => ({ ok: true, priceMinor: '475' })) {
  const html = await readFile(new URL('../../examples/cafe/index.html', import.meta.url), 'utf8');
  const dom = new JSDOM(html, { url: 'http://cafe.test/', runScripts: 'outside-only', pretendToBeVisual: true });
  t.after(() => dom.window.close());
  const { window } = dom;
  // jsdom has no browser top layer; these preserve the dialog's open/closed contract for DOM assertions.
  window.HTMLDialogElement.prototype.showModal = function () { this.open = true; this.querySelector('[autofocus]')?.focus(); };
  window.HTMLDialogElement.prototype.close = function () { this.open = false; };
  window.fetch = fetch;
  window.__previewFixture = model;
  window.eval(await appBundle());
  await waitFor(() => window.document.querySelector('#configuration-title'));
  await waitFor(() => !window.document.querySelector('.account-nav button')?.disabled);
  const setInput = (selector, value) => {
    const input = window.document.querySelector(selector);
    assert.ok(input, `Missing input: ${selector}`);
    Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set.call(input, value);
    input.dispatchEvent(new window.Event('input', { bubbles: true }));
  };
  const submit = selector => window.document.querySelector(selector).dispatchEvent(new window.Event('submit', { bubbles: true, cancelable: true }));
  const go = async route => { window.location.hash = route; await tick(); await new Promise(resolve => setTimeout(resolve, 20)); };
  return { window, document: window.document, setInput, submit, go };
}

test('UI disables unavailable choices, preserves the draft through signup, clears passwords, and saves the same cup', async t => {
  const calls = [], seen = [];
  let model = { ok: true, priceMinor: '475' };
  let signupBody;
  const ui = await mount(t, async (path, init) => {
    calls.push(path);
    if (path === '/auth/session') return response({ error: 'auth.required' }, 401);
    if (path === '/auth/signup') { signupBody = JSON.parse(init.body); return response(session()); }
    if (path.endsWith('/list')) return success(init, []);
    if (path.endsWith('/save')) {
      const input = JSON.parse(init.body).input;
      return success(init, recipe('saved', { ...input, priceMinor: '9007199254740993' }));
    }
    assert.fail(`Unexpected request: ${path}`);
  }, config => {
    seen.push({ ...config });
    return config.temperature === 'iced' && config.size === 'small' ? { ok: false, error: 'small_iced' } : model;
  });
  const { document, setInput, submit, go } = ui;
  assert.deepEqual(seen[0], configuration());
  document.querySelector('input[name="temperature"][value="iced"]').click();
  await waitFor(() => document.querySelector('input[value="small"]').disabled);
  document.querySelector('input[name="size"][value="small"]').click();
  await tick();
  assert.match(document.querySelector('#size-availability').textContent, /no room for ice/);
  assert.equal(document.querySelector('input[value="small"]').checked, false);
  assert.ok(document.querySelector('input[value="regular"]').checked);
  assert.ok(document.querySelector('input[value="iced"]').checked);
  assert.equal(document.querySelector('.save-form button[type="submit"]').disabled, false);
  assert.equal(document.querySelector('.rule-message'), null);
  assert.equal(calls.filter(path => path.startsWith('/api/')).length, 0);

  model = { ok: true, priceMinor: '675' };
  document.querySelector('input[name="size"][value="large"]').click();
  document.querySelector('input[name="milk"][value="oat"]').click();
  setInput('#recipe-name', '  My slow Sunday ☕  ');
  await tick();
  submit('.save-form');
  await waitFor(() => document.querySelector('dialog[open]'));
  setInput('#username', 'alice'); setInput('#password', 'a truly long password');
  submit('dialog form');
  assert.equal(document.querySelector('#password').value, '');
  await waitFor(() => !document.querySelector('dialog'));
  await waitFor(() => document.querySelector('.save-form button[type="submit"]').textContent.includes('Save recipe'));
  assert.deepEqual(signupBody, { username: 'alice', password: 'a truly long password' });
  assert.equal(document.querySelector('#recipe-name').value, '  My slow Sunday ☕  ');
  assert.ok(document.querySelector('input[value="large"]').checked);
  assert.ok(document.querySelector('input[value="oat"]').checked);
  assert.ok(document.querySelector('input[value="iced"]').checked);
  await waitFor(() => !document.querySelector('.save-form button[type="submit"]').disabled);
  submit('.save-form');
  await waitFor(() => document.querySelector('.global-notice').textContent.includes('Recipe saved'));
  await go('saved');
  await waitFor(() => document.querySelector('.recipe-card'));
  assert.equal(document.querySelector('.recipe-title h2').textContent, 'My slow Sunday ☕');
  assert.match(document.querySelector('.recipe-title').textContent, /\$90,071,992,547,409\.93/);
  assert.match(document.querySelector('.recipe-description').textContent, /Iced · Large · Oat milk/);
  assert.equal(ui.window.localStorage.length, 0); assert.equal(ui.window.sessionStorage.length, 0);
  assert.doesNotMatch(document.body.textContent, /a truly long password/);
});

test('UI auth errors are accessible and safe; switching modes and closing clears the password', async t => {
  const ui = await mount(t, async path => response(path === '/auth/session' ? { error: 'auth.required' } :
    { error: 'auth.invalid_credentials', detail: 'private backend detail' }, 401));
  const { document, setInput, submit } = ui;
  document.querySelector('.account-nav .text-button').click();
  await waitFor(() => document.querySelector('dialog[open]'));
  setInput('#username', 'alice'); setInput('#password', 'wrong secret password'); submit('dialog form');
  assert.equal(document.querySelector('#password').value, '');
  await waitFor(() => document.querySelector('#account-error'));
  assert.equal(document.querySelector('#account-error').getAttribute('role'), 'alert');
  assert.match(document.querySelector('#account-error').textContent, /do not match/);
  assert.doesNotMatch(document.body.textContent, /private backend|wrong secret/);
  setInput('#password', 'clear this on mode change');
  document.querySelector('.account-modes button').click();
  await tick(); assert.equal(document.querySelector('#password').value, '');
  setInput('#password', 'clear this on close');
  document.querySelector('.close-button').click();
  await waitFor(() => !document.querySelector('dialog'));
  document.querySelector('.account-nav .text-button').click();
  await waitFor(() => document.querySelector('dialog[open]'));
  assert.equal(document.querySelector('#password').value, '');
  assert.equal(ui.window.localStorage.length, 0); assert.equal(ui.window.sessionStorage.length, 0);
});

test('UI deletion requires confirmation, cancel sends nothing, and logout hides the collection', async t => {
  let deletes = 0;
  const ui = await mount(t, async (path, init) => {
    if (path === '/auth/session') return response(session());
    if (path === '/auth/logout') return response({ ok: true });
    if (path.endsWith('/list')) return success(init, [recipe()]);
    if (path.endsWith('/delete')) { ++deletes; return success(init, null); }
    assert.fail(`Unexpected request: ${path}`);
  });
  const { document, go } = ui;
  await go('saved'); await waitFor(() => document.querySelector('.recipe-card'));
  document.querySelector('.delete-button').click();
  await waitFor(() => document.querySelector('#delete-title'));
  assert.equal(deletes, 0);
  assert.equal(document.querySelector('dialog').getAttribute('aria-labelledby'), 'delete-title');
  document.querySelector('.dialog-actions .secondary').click();
  await waitFor(() => !document.querySelector('dialog'));
  assert.equal(deletes, 0); assert.ok(document.querySelector('.recipe-card'));
  document.querySelector('.delete-button').click();
  await waitFor(() => document.querySelector('#delete-title'));
  document.querySelector('.dialog-actions .danger').click();
  await waitFor(() => !document.querySelector('.recipe-card'));
  assert.equal(deletes, 1);
  document.querySelector('.account-nav .text-button').click();
  await waitFor(() => document.querySelector('.empty-state h2')?.textContent === 'Good cups deserve keeping.');
  assert.equal(document.querySelectorAll('.recipe-card').length, 0);
  assert.equal(document.querySelector('dialog'), null);
});
