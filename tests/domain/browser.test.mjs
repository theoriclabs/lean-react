// Mounted browser tests of the compiled LeanReact.Domain surface (LeanJS, React, jsdom) over
// the post's domain (LeanAPI's `TestsCore.PostPart1`) and its generated route client
// (decision-5 envelope, decision-15 wire values). The 17 scenarios of the milestone-1 suite,
// ported to typed form models and the mounted `App` (`app.test.mjs` adds 9 more).
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {JSDOM} from 'jsdom';
import {action, runAction} from '../../engine/runtime/actions.mjs';
import {createJsonBridge, createContractInterpreter} from '../../engine/adapters/leanjs-contract.mjs';
const {window} = new JSDOM('<!doctype html><html><body></body></html>');
Object.assign(globalThis, {window, document: window.document, HTMLElement: window.HTMLElement, IS_REACT_ACT_ENVIRONMENT: true});
const React = await import('react');
const {createRoot} = await import('react-dom/client');
const {runtime, mountElement, ctor} = await import('../../engine/adapters/leanjs-react.mjs');
const program = await import('./generated/domain.mjs');
const generated = await import('./generated/post/operations.mjs');
const {formatRfc3339} = await import('../../../leanapi/LeanContract/Codecs.mjs');
const json = createJsonBridge(program);
const unit = ctor('PUnit.unit');
const none = ctor('Option.none');
const some = value => ctor('Option.some', [value]);
const list = values => values.reduceRight((tail, head) => ctor('List.cons', [head, tail]), ctor('List.nil'));
const array = value => {const result=[]; while(value.tag==='List.cons'){result.push(value.fields[0]); value=value.fields[1];} assert.equal(value.tag, 'List.nil'); return result;};
const deferred = () => {let resolve; const promise = new Promise(done => {resolve=done;}); return {promise, resolve};};
const settle = () => React.act(async () => {for (let i = 0; i < 5; i++) await new Promise(r => setTimeout(r, 0));});
const make = (name, values) => {
  const declaration = program.__leanjs.constructors.find(value => value.name === name);
  assert.ok(declaration, name);
  return ctor(name, declaration.fieldInfo.map(field => {
    assert.ok(Object.hasOwn(values, field.name), `${name}.${field.name}`);
    return values[field.name];
  }));
};
function context({generation=0n, current=()=>generation, events=[], authenticated=()=>{}}={}) {
  return program['PostViews.shellProps'](generation, action(current),
    error => action(() => {events.push(['framework', error]); return unit;}),
    path => action(() => {events.push(['navigate', path]); return unit;}),
    action(() => {authenticated(); events.push(['authenticated']); return unit;}));
}
const shell = (client, props=context(), requestClient=none) => make('LeanReact.Domain.Shell.mk', {toShellProps: props, client, requestClient});
function http(handler) {
  const requests = [];
  const client = generated.createClient({fetch: async (url, init) => {
    const request = {url, method: init.method, body: init.body ? JSON.parse(init.body) : null};
    requests.push(request);
    const response = await handler(request, requests.length);
    return {status: response.status ?? 200, text: async () => JSON.stringify(response.body)};
  }});
  return {requests, client, interpreter: createContractInterpreter({program, client})};
}
const ok = value => ({body: {ok: value}});
const domainError = tag => ({status: 422, body: {error: tag}});
const visible = names => ({tag: 'visible', value: {guests: names.map(name => ({name}))}});
const hidden = 'hidden';
const page = guests => ok({title: 'Fixture party', description: '', date: '1970-01-01T00:03:20Z', guests});
const PRIVATE = /The host is keeping the guest list private\./;
async function mounted(render) {
  const container=document.createElement('div'); document.body.append(container);
  const root=createRoot(container);
  await React.act(() => root.render(render()));
  return {container, root, render: async next => React.act(() => root.render(next())),
    close: async () => {await React.act(() => root.unmount()); container.remove();}};
}
function appView(interpreter, {location='/parties/1', actor=none, generation=0n, events=[], descriptor}={}) {
  const app = descriptor ?? program['PostViews.appComponent'](interpreter);
  return props => mountElement(app, program['PostViews.appProps'](context({generation: props?.generation ?? generation, events}),
    props?.location ?? location, props?.actor ?? actor));
}
const setInput = async (container, name, value) => {
  const input=container.querySelector(`[name="${name}"]`); assert.ok(input, name);
  const prototype=input.tagName==='SELECT' ? window.HTMLSelectElement.prototype : window.HTMLInputElement.prototype;
  await React.act(() => {Object.getOwnPropertyDescriptor(prototype, 'value').set.call(input, value); input.dispatchEvent(new window.Event('change', {bubbles:true})); input.dispatchEvent(new window.Event('input', {bubbles:true}));});
};
const submit = async container => {await React.act(() => container.querySelector('form').dispatchEvent(new window.Event('submit', {bubbles:true, cancelable:true}))); await settle();};
const press = async (container, label) => {
  const button=[...container.querySelectorAll('button')].find(b => b.textContent === label); assert.ok(button, label);
  await React.act(() => button.dispatchEvent(new window.MouseEvent('click', {bubbles:true}))); await settle();
};
// A form model (`useDomainForm`) mounted on its own: fields are form, pending, feedback, submit,
// readPending, readFeedback, cancel.
async function formModel(hook) {
  let model;
  const Source=runtime.component(() => runtime.mapHook(value => {model=value; return null;}, hook()), {name:'FormModel'});
  const view=await mounted(() => runtime.element(Source, {}));
  return {view, model: () => model, binding: () => model.fields[0].fields[1]};
}
const hostRaw = (date='200') => program['DomainBrowser.hostRaw']('Valid party', '', date, 'everyone');

test('shared native/LeanJS checked parsers match golden raw cases', async () => {
  const expected=JSON.parse(await readFile(new URL('./generated/scalars.json', import.meta.url), 'utf8'));
  assert.deepEqual(array(program['DomainBrowser.results']), expected);
  for(const pair of array(program['DomainBrowser.inputs']))
    assert.equal(program['DomainBrowser.parseCase'](...pair.fields), expected[array(program['DomainBrowser.inputs']).indexOf(pair)]);
  assert.equal(program['DomainBrowser.parseHost'](' Dinner ', '', '9007199254740993', 'everyone'), 'ok:Dinner:9007199254740993');
  assert.match(program['DomainBrowser.parseHost']('', '', 'invalid', 'everyone'), /^error:/);
  assert.equal(json.fromLean(json.toLean({alpha:[null,true,'東京😀',1.25]})).alpha[3], 1.25);
  assert.throws(() => json.toLean(9007199254740992), /json.unsafe_number/);
});

test('generated contracts keep hidden and empty guest lists distinct and expose only the api', async () => {
  const wire=JSON.parse(await readFile(new URL('./generated/wire.json', import.meta.url), 'utf8'));
  // Decision 15: a payload-free constructor is a bare string; an empty visible list is not hidden.
  assert.equal(wire.hidden, 'hidden');
  assert.deepEqual(wire.empty, {tag:'visible', value:{guests:[]}});
  assert.deepEqual(wire.variants, ['everyone','attendees','hostOnly']);
  const pageCodec=generated.operations.getParty.output;
  const value=guests => ({title:'Party', date:'1970-01-01T00:03:20Z', description:'', guests});
  for(const guests of [wire.hidden, wire.empty, wire.visible])
    assert.deepEqual(pageCodec.encode(pageCodec.decode(value(guests))), value(guests));
  for(const guests of [{tag:'hidden', value:[]}, {tag:'hidden', value:null, count:1}, {tag:'visible', value:{guests:[], total:3}}])
    assert.throws(() => pageCodec.decode(value(guests)));
  assert.equal(generated.manifest.operations.length, 6);
  const manifest=JSON.stringify(generated.manifest);
  // No stored-only type reaches the public contract: the hash, the credential table, the RSVP rows.
  for(const privateType of ['PasswordHash','Credential','Rsvp','Session.digest']) assert.ok(!manifest.includes(`"name":"${privateType}"`), privateType);
});

test('compiled guestsView renders hidden and authorized empty differently', async () => {
  const view=value => program['DomainBrowser.guestView'](value);
  const mountedView=await mounted(() => view(ctor('GuestList.visible', [list([])])));
  try {
    assert.equal(mountedView.container.textContent, ''); assert.ok(mountedView.container.querySelector('ul'));
    await mountedView.render(() => view(ctor('GuestList.hidden')));
    assert.match(mountedView.container.textContent, PRIVATE);
    assert.equal(mountedView.container.querySelector('ul'), null);
  } finally {await mountedView.close();}
});

test('compiled host form retains invalid drafts, accumulates errors, and prevents duplicate pending calls', async () => {
  const response=deferred(), events=[];
  const server=http(async () => {await response.promise; return {body: JSON.parse('{"ok":1}')};});
  const {view, model, binding}=await formModel(() => program['DomainBrowser.hostForm'](shell(server.interpreter, context({events}))));
  try {
    await React.act(() => runAction(binding().fields[1](program['DomainBrowser.hostRaw']('', '', 'local date', 'everyone'))));
    await React.act(() => runAction(model().fields[3]));
    assert.equal(server.requests.length, 0);
    const draft=model().fields[0].fields[0];
    assert.equal(draft.fields[1].tag, 'Except.error');
    assert.ok(array(draft.fields[1].fields[0].fields[1]).length >= 1, 'independent fields accumulate');
    assert.equal(json.fromLean(binding().fields[0]).date, 'local date');
    await React.act(() => runAction(binding().fields[1](program['DomainBrowser.hostRaw'](' Dinner ', '', '9007199254740993', 'everyone'))));
    let pending;
    await React.act(async () => {pending=runAction(model().fields[3]); await runAction(model().fields[3]);});
    assert.equal(server.requests.length, 1);
    assert.equal(model().fields[1].tag, 'Bool.true');
    assert.equal(server.requests[0].url, '/parties');
    assert.equal(server.requests[0].body.date, formatRfc3339(9007199254740993n));
    assert.equal(server.requests[0].body.title, 'Dinner');
    for(const actorField of ['me','now','host']) assert.ok(!Object.hasOwn(server.requests[0].body, actorField), actorField);
    await React.act(async () => {response.resolve(); await pending;});
    assert.equal(model().fields[1].tag, 'Bool.false');
    assert.deepEqual(events, [['navigate','/parties/1']]);
  } finally {await view.close();}
});

test('typed scalar editors: password, email, optional Text and every enum choice', async () => {
  const never=http(async () => {throw new Error('invalid draft submitted');});
  const Source=runtime.component(() => program['DomainBrowser.settingsFormView'](shell(never.interpreter)), {name:'SettingsEditors'});
  const view=await mounted(() => runtime.element(Source, {}));
  try {
    const {container}=view;
    assert.equal(container.querySelector('[name="secret"]').type, 'password');
    assert.equal(container.querySelector('[name="mailbox"]').type, 'email');
    assert.equal(container.querySelector('[name="notes"]').required, false);
    const choice=container.querySelector('[name="audience"]');
    assert.deepEqual([...choice.options].map(option => option.value), ['everyone','members','staff','hostsOnly']);
    assert.equal(container.querySelector('label[for="domain-field-secret"]').textContent, 'Secret');
    await submit(container); assert.equal(never.requests.length, 0);
    assert.ok(container.querySelector('[role="alert"]'));
  } finally {await view.close();}
});

test('duplicate-email errors bind the actual field and authentication is established before success navigation', async () => {
  let reject=true, authenticated=false; const events=[];
  const server=http(async () => reject ? domainError('emailTaken') : ok(1));
  const Source=runtime.component(() => program['DomainBrowser.signUpView'](shell(server.interpreter, context({events, authenticated:()=>{authenticated=true;}}))), {name:'SignUp'});
  const view=await mounted(() => runtime.element(Source, {}));
  try {
    await setInput(view.container,'name','Alice');
    await setInput(view.container,'email',' ALICE@Example.COM ');
    await setInput(view.container,'password','Fictional password');
    await submit(view.container);
    assert.equal(server.requests.length, 1);
    assert.equal(server.requests[0].body.email, 'alice@example.com');
    assert.match(view.container.textContent, /email: This email already has an account/);
    assert.equal(authenticated, false);
    reject=false; await submit(view.container);
    assert.equal(authenticated, true);
    assert.deepEqual(events, [['authenticated'],['navigate','/parties/new']]);
  } finally {await view.close();}
});

test('a mounted page discards visible data on a scope change and ignores old actor generations', async () => {
  const old=deferred(); let calls=0;
  const server=http(async () => {
    calls++;
    if(calls===1) {await old.promise; return page(visible(['Old Alice']));}
    if(calls===2 || calls===4) return page(hidden);
    return page(visible(['Current Bob']));
  });
  const render=appView(server.interpreter, {actor: some('1')});
  const view=await mounted(() => render());
  try {
    await view.render(() => render({actor: some('2'), generation: 1n})); await settle();
    assert.match(view.container.textContent, PRIVATE);
    assert.ok(!view.container.textContent.includes('Old Alice'));
    await React.act(async () => {old.resolve(); await old.promise;}); await settle();
    assert.ok(!view.container.textContent.includes('Old Alice'));
    await view.render(() => render({actor: some('2'), generation: 2n})); await settle();
    assert.match(view.container.textContent, /Current Bob/);
    await view.render(() => render({actor: none, generation: 3n})); await settle();
    assert.equal(server.requests.length, 4, 'logout starts an independent scope');
    assert.match(view.container.textContent, PRIVATE);
    assert.ok(!view.container.textContent.includes('Current Bob'));
  } finally {await view.close();}
});

test('framework session expiry and network errors remain typed shared channels', async () => {
  for(const [kind, body] of [['unauthenticated', {error:'unauthorized'}], ['unauthenticated', {tag:'unauthenticated'}], ['transport', null]]) {
    const events=[];
    const server=http(async () => {
      if(kind==='transport') throw new TypeError('simulated network failure');
      return {status:401, body};
    });
    const view=await mounted(() => appView(server.interpreter, {events})());
    try {
      await settle();
      assert.match(view.container.textContent, /Unable to load/);
      const failure=events.find(event => event[0]==='framework'); assert.ok(failure, kind);
      assert.equal(failure[1].tag, `Contract.CallError.${kind}`);
    } finally {await view.close();}
  }
});

test('UTC editor/display preserves leap dates, pre-epoch seconds and exact native wire values', async () => {
  const parse=program['DomainBrowser.dateDraft'], display=program['DomainBrowser.dateDisplay'];
  assert.equal(parse('1970-01-01T00:00'), '0');
  assert.equal(display(-1n), '1969-12-31T23:59:59');
  assert.equal(parse('2000-02-29T12:34:56'), '951827696');
  assert.equal(parse('2000-02-29T12:34:56.000'),'951827696');
  assert.equal(parse('2000-02-29T12:34:56.001'),'2000-02-29T12:34:56.001');
  for(const invalid of ['1900-02-29T00:00','2026-04-31T00:00','2026-01-01T24:00','2026-01-01T00:00:60']) assert.equal(parse(invalid),invalid);
  for(const value of [-62135596800n, -1n, 0n, 951827696n, 253402300799n]) assert.equal(parse(display(value)),String(value));
  const server=http(async () => ok(1));
  const Source=runtime.component(() => program['DomainBrowser.hostFormView'](shell(server.interpreter)),{name:'UTCEditor'});
  const view=await mounted(() => runtime.element(Source,{}));
  try {
    assert.equal(view.container.querySelector('[name="date"]').type,'datetime-local');
    assert.equal(view.container.querySelector('[name="date"]').getAttribute('aria-label'),'Date (UTC)');
    await setInput(view.container,'title','UTC party');
    await setInput(view.container,'date','2000-02-29T12:34:56');
    await submit(view.container);
    assert.equal(server.requests.length,1);
    assert.equal(server.requests[0].body.date,'2000-02-29T12:34:56Z');
  } finally {await view.close();}
});

test('bad credentials use the explicit notice without authentication or navigation', async () => {
  const events=[];
  const server=http(async () => domainError('wrongEmailOrPassword'));
  const Source=runtime.component(() => program['DomainBrowser.signInView'](shell(server.interpreter,context({events}))),{name:'SignIn'});
  const view=await mounted(() => runtime.element(Source,{}));
  try {
    await setInput(view.container,'email','bob@example.test');
    await setInput(view.container,'password','Fictional password');
    await submit(view.container);
    assert.equal(server.requests.length,1);
    assert.match(view.container.textContent,/Wrong email or password\./);
    assert.deepEqual(events,[]);
  } finally {await view.close();}
});

test('bound actions refresh after RSVP, present domain failures, and redirect after cancelling', async () => {
  const cases=[
    {button:"I'm going", reply:ok(null), reload:true},
    {button:"I'm going", reply:domainError('alreadyStarted'), message:/This party has already started\./},
    {button:'Cancel party', reply:domainError('notHost'), message:/Only the host can cancel this party\./},
    {button:'Cancel party', reply:ok(null), event:['navigate','/parties/new']},
  ];
  for(const item of cases) {
    const events=[]; let pages=0;
    const server=http(async request => {
      if(request.method==='GET') {pages++; return page(hidden);}
      return item.reply;
    });
    const view=await mounted(() => appView(server.interpreter, {actor: some('1'), events})());
    try {
      await settle();
      assert.equal(view.container.querySelector('[name="party"]'), null, 'the path field is bound, never edited');
      await press(view.container, item.button);
      const posts=server.requests.filter(request => request.method==='POST');
      assert.equal(posts.length, 1, item.button);
      assert.match(posts[0].url, /^\/parties\/1\/(rsvp|cancel)$/);
      if(item.message) {assert.match(view.container.textContent, item.message); assert.deepEqual(events, []); assert.equal(pages, 1);}
      if(item.reload) {assert.equal(pages, 2, 'a successful command reloads the page'); assert.deepEqual(events, []);}
      if(item.event) assert.deepEqual(events, [item.event]);
    } finally {await view.close();}
  }
});

test('every visibility/viewer row traverses real Flow output, HTTP codecs, exact bytes and the mounted page', async () => {
  const cases=JSON.parse(await readFile(new URL('./generated/matrix.json',import.meta.url),'utf8'));
  assert.equal(cases.length,12);
  for(const item of cases) {
    const allowed=item.visibility==='everyone' || item.actorLabel==='host' ||
      (item.visibility==='attendees' && item.actorLabel==='attendee');
    const guests=item.value.guests;
    assert.equal(typeof guests==='string' ? guests : guests.tag, allowed ? 'visible' : 'hidden', `${item.visibility}/${item.actorLabel}`);
    assert.equal(item.projectionReads, allowed ? 1 : 0, 'denial does not execute the join');
    const bytes=JSON.stringify(guests);
    if(!allowed) {
      assert.equal(bytes, '"hidden"');
      for(const secret of ['Alice','Bob','Carol','email','key','count','total']) assert.ok(!bytes.includes(secret));
    } else assert.deepEqual(guests.value.guests, [{name:'Guest Bob'}]);
    const server=http(async () => ok(item.value));
    const actor=item.actor===null ? none : some(String(item.actor));
    const view=await mounted(() => appView(server.interpreter, {location:`/parties/${item.reference}`, actor})());
    try {
      await settle();
      assert.equal(server.requests.length,1);
      assert.equal(server.requests[0].url, `/parties/${item.reference}`);
      assert.equal(view.container.textContent.includes('Guest Bob'), allowed);
      assert.equal(PRIVATE.test(view.container.textContent), !allowed);
      assert.ok(!view.container.textContent.includes('@example.test'));
    } finally {await view.close();}
  }
});

test('a successful RSVP reloads the page and a privacy change replaces the whole guest list', async () => {
  let pages=0, privateNow=false;
  const server=http(async request => {
    if(request.method==='GET') {pages++; return page(privateNow ? hidden : visible(['Current Bob']));}
    privateNow=true;
    return ok(null);
  });
  const view=await mounted(() => appView(server.interpreter, {actor: some('1')})());
  try {
    await settle();
    assert.match(view.container.textContent, /Current Bob/);
    await press(view.container, "I'm going");
    assert.equal(pages, 2, 'RSVP reloads the page');
    assert.match(view.container.textContent, PRIVATE);
    assert.ok(!view.container.textContent.includes('Current Bob'));
  } finally {await view.close();}
});

test('cancelled and unmounted submissions cannot navigate when old responses settle', async () => {
  for(const mode of ['cancel','unmount']) {
    const response=deferred(), events=[];
    const server=http(async () => {await response.promise; return ok(1);});
    const {view, model, binding}=await formModel(() => program['DomainBrowser.hostForm'](shell(server.interpreter, context({events}))));
    let closed=false;
    try {
      await React.act(() => runAction(binding().fields[1](hostRaw())));
      let pending;
      await React.act(() => {pending=runAction(model().fields[3]);});
      assert.equal(server.requests.length,1);
      if(mode==='cancel') {
        await React.act(() => runAction(model().fields[6]));
        assert.equal(model().fields[1].tag,'Bool.false');
      } else {await view.close(); closed=true;}
      await React.act(async () => {response.resolve(); await pending;});
      assert.deepEqual(events,[]);
    } finally {if(!closed) await view.close();}
  }
});

test('request-scoped transport aborts an active submit on cancellation and unmount', async () => {
  for(const mode of ['cancel','unmount']) {
    const started=deferred(), events=[]; let signal;
    const client=generated.createClient({fetch: async (_url, init) => {
      signal=init.signal; started.resolve();
      await new Promise((_, reject) => {signal.addEventListener('abort', () => reject(new DOMException('Cancelled','AbortError')), {once:true});});
    }});
    const base=createContractInterpreter({program, client});
    const factory=request => createContractInterpreter({program, client, request});
    const {view, model, binding}=await formModel(() => program['DomainBrowser.hostForm'](shell(base, context({events}), some(factory))));
    let closed=false;
    try {
      await React.act(() => runAction(binding().fields[1](hostRaw())));
      let pending;
      await React.act(async () => {pending=runAction(model().fields[3]); await started.promise;});
      assert.ok(signal instanceof AbortSignal); assert.equal(signal.aborted,false);
      if(mode==='cancel') await React.act(() => runAction(model().fields[6]));
      else {await view.close(); closed=true;}
      await React.act(async () => {await pending;});
      assert.equal(signal.aborted,true);
      assert.deepEqual(events,[]);
    } finally {if(!closed) await view.close();}
  }
});

test('request-scoped page loads abort obsolete actor generations and unmount', async () => {
  const signals=[];
  const client=generated.createClient({fetch: async (_url, init) => {
    signals.push(init.signal);
    await new Promise((_, reject) => init.signal.addEventListener('abort', () => reject(new DOMException('Cancelled','AbortError')), {once:true}));
  }});
  const base=createContractInterpreter({program, client});
  const factory=request => createContractInterpreter({program, client, request});
  const events=[];
  const render=appView(base, {descriptor: program['DomainBrowser.appWithRequests'](base, factory), actor: some('1'), events});
  const view=await mounted(() => render());
  let closed=false;
  try {
    await settle();
    assert.equal(signals.length,1); assert.equal(signals[0].aborted,false);
    await view.render(() => render({actor: some('2'), generation: 1n})); await settle();
    assert.equal(signals.length,2); assert.equal(signals[0].aborted,true); assert.equal(signals[1].aborted,false);
    await view.close(); closed=true;
    assert.equal(signals[1].aborted,true); assert.deepEqual(events,[]);
  } finally {if(!closed) await view.close();}
});

test('an old cancelled reply cannot release or abort a newer submission', async () => {
  const first=deferred(), second=deferred(), events=[], signals=[];
  const server=http(async (_request, index) => {
    await (index===1 ? first.promise : second.promise);
    return ok(index);
  });
  const original=server.client;
  const client={...original, call: async (id, input, options) => {signals.push(options.signal); return original.call(id, input, options);}};
  const base=createContractInterpreter({program, client});
  const factory=request => createContractInterpreter({program, client, request});
  const {view, model, binding}=await formModel(() => program['DomainBrowser.hostForm'](shell(base, context({events}), some(factory))));
  try {
    await React.act(() => runAction(binding().fields[1](hostRaw())));
    let oldPending, newPending;
    await React.act(() => {oldPending=runAction(model().fields[3]);});
    await React.act(() => runAction(model().fields[6]));
    await React.act(() => {newPending=runAction(model().fields[3]);});
    assert.equal(server.requests.length,2); assert.equal(signals[0].aborted,true); assert.equal(signals[1].aborted,false);
    await React.act(async () => {first.resolve(); await oldPending;});
    assert.equal(model().fields[1].tag,'Bool.true'); assert.equal(signals[1].aborted,false); assert.deepEqual(events,[]);
    await React.act(async () => {second.resolve(); await newPending;});
    assert.equal(model().fields[1].tag,'Bool.false'); assert.deepEqual(events,[['navigate','/parties/2']]);
  } finally {first.resolve(); second.resolve(); await view.close();}
});
