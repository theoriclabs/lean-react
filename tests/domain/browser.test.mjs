import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {JSDOM} from 'jsdom';
import {action, pureAction, runAction} from '../../engine/runtime/actions.mjs';
import {createJsonBridge, createContractInterpreter} from '../../engine/adapters/leanjs-contract.mjs';
const {window} = new JSDOM('<!doctype html><html><body></body></html>');
Object.assign(globalThis, {window, document: window.document, HTMLElement: window.HTMLElement, IS_REACT_ACT_ENVIRONMENT: true});
const React = await import('react');
const {createRoot} = await import('react-dom/client');
const {runtime, mountElement, ctor} = await import('../../engine/adapters/leanjs-react.mjs');
const program = await import('./generated/domain.mjs');
const generated = await import('./generated/operations.mjs');
const {formatRfc3339} = await import('../../engine/LeanContract/Codecs.mjs');
const json = createJsonBridge(program);
const unit = ctor('PUnit.unit');
const none = ctor('Option.none');
const bool = value => ctor(value ? 'Bool.true' : 'Bool.false');
const list = values => values.reduceRight((tail, head) => ctor('List.cons', [head, tail]), ctor('List.nil'));
const array = value => {const result=[]; while(value.tag==='List.cons'){result.push(value.fields[0]); value=value.fields[1];} assert.equal(value.tag, 'List.nil'); return result;};
const ok = result => {assert.equal(result.tag, 'Except.ok'); return result.fields[0];};
const deferred = () => {let resolve; const promise = new Promise(done => {resolve=done;}); return {promise, resolve};};
const make = (name, values) => {
  const declaration = program.__leanjs.constructors.find(value => value.name === name);
  assert.ok(declaration, name);
  return ctor(name, declaration.fieldInfo.map(field => {
    assert.ok(Object.hasOwn(values, field.name), `${name}.${field.name}`);
    return values[field.name];
  }));
};
function context({generation=0n, current=()=>generation, events=[], authenticated=()=>{}}={}) {
  return make('LeanReact.Domain.ShellProps.mk', {
    generation, currentGeneration: action(current),
    framework: error => action(() => {events.push(['framework', error]); return unit;}),
    navigate: path => action(() => {events.push(['navigate', path]); return unit;}),
    refresh: action(() => {events.push(['refresh']); return unit;}),
    authenticationChanged: action(() => {authenticated(); events.push(['authenticated']); return unit;}),
  });
}
const shell = (client, props=context(), requestClient=none) => make('LeanReact.Domain.Shell.mk', {toShellProps: props, client, requestClient});
// Decision 15: references are bare integers (bigint in JS), times RFC 3339 UTC strings.
const refWire = (_type, key='1') => BigInt(key);
const legacyRef = (type, key='1') => ({type:{package:'domain', name:`Partiful.${type}`}, scope:'default', key});
const sentRef = (key='1') => Number(key);
function http(handler) {
  const requests=[];
  const client = generated.createClient({fetch: async (url, init) => {
    const request=JSON.parse(init.body); requests.push({url, request, init});
    const response=await handler(request, requests.length);
    return {status: response.status ?? 200, json: async () => response.body ?? {operation: request.operation, tag:'success', value:response.value}};
  }});
  return {requests, client, interpreter:createContractInterpreter({program, client})};
}
async function mounted(render) {
  const container=document.createElement('div'); document.body.append(container);
  const root=createRoot(container);
  await React.act(() => root.render(render()));
  return {container, root, render: async next => React.act(() => root.render(next())),
    close: async () => {await React.act(() => root.unmount()); container.remove();}};
}
const setInput = async (container, name, value) => {
  const input=container.querySelector(`[name="${name}"]`); assert.ok(input, name);
  const prototype=input.tagName==='SELECT' ? window.HTMLSelectElement.prototype : window.HTMLInputElement.prototype;
  await React.act(() => {Object.getOwnPropertyDescriptor(prototype, 'value').set.call(input, value); input.dispatchEvent(new window.Event('change', {bubbles:true})); input.dispatchEvent(new window.Event('input', {bubbles:true}));});
};
const submit = container => React.act(() => container.querySelector('form').dispatchEvent(new window.Event('submit', {bubbles:true, cancelable:true})));

test('shared native/LeanJS checked parsers match golden raw cases', async () => {
  const expected=JSON.parse(await readFile(new URL('./generated/scalars.json', import.meta.url), 'utf8'));
  assert.deepEqual(array(program['DomainBrowser.results']), expected);
  for(const pair of array(program['DomainBrowser.inputs']))
    assert.equal(program['DomainBrowser.parseCase'](...pair.fields), expected[array(program['DomainBrowser.inputs']).indexOf(pair)]);
  assert.equal(program['DomainBrowser.parseHost'](' Dinner ', '', '9007199254740993', 'public'), 'ok:Dinner:9007199254740993');
  assert.match(program['DomainBrowser.parseHost']('', '', 'invalid', 'public'), /^error:/);
  assert.equal(json.fromLean(json.toLean({alpha:[null,true,'東京😀',1.25]})).alpha[3], 1.25);
  assert.throws(() => json.toLean(9007199254740992), /json.unsafe_number/);
});

test('generated contracts preserve exact hidden bytes, distinguish empty, and expose only eight operations', async () => {
  const wire=JSON.parse(await readFile(new URL('./generated/wire.json', import.meta.url), 'utf8'));
  // Decision 15: a payload-free constructor is a bare string on the wire.
  assert.deepEqual(wire.hidden, 'hidden');
  assert.notDeepEqual(wire.hidden, wire.empty);
  const pageCodec=Object.values(generated.operations).find(op => op.identity.name==='partyPage').output;
  const page=guests => ({title:'Party', date:'1970-01-01T00:03:20Z', description:'', visibility:wire.variants[0], guests});
  for(const guests of [wire.hidden, wire.empty, wire.visible])
    assert.deepEqual(pageCodec.encode(pageCodec.decode(page(guests))), page(guests));
  // The milestone-1 time form still decodes during the transition, normalized to RFC 3339.
  assert.deepEqual(pageCodec.decode({...page(wire.empty), date:{tag:'int', value:'200'}}).date, '1970-01-01T00:03:20Z');
  for(const guests of [{tag:'hidden', value:[]}, {tag:'hidden', value:null, count:1}, {tag:'hidden', value:null, guests:[{name:'Secret'}]}])
    assert.throws(() => pageCodec.decode(page(guests)));
  assert.equal(generated.manifest.operations.length, 8);
  const manifest=JSON.stringify(generated.manifest);
  for(const privateField of ['passwordHash','sessionDigest','holderId','Party.Guests']) assert.ok(!manifest.includes(privateField));
});

test('compiled guestsView renders hidden and authorized empty differently', async () => {
  const view=value => program['DomainBrowser.guestView'](value);
  const mountedView=await mounted(() => view(ctor('LeanApp.Domain.Disclosure.visible', [list([])])));
  try {
    assert.equal(mountedView.container.textContent, ''); assert.ok(mountedView.container.querySelector('ul'));
    await mountedView.render(() => view(ctor('LeanApp.Domain.Disclosure.hidden')));
    assert.equal(mountedView.container.textContent, 'The guest list is private.');
    assert.equal(mountedView.container.querySelector('ul'), null);
  } finally {await mountedView.close();}
});

test('compiled host form retains invalid drafts, accumulates errors, and prevents duplicate pending calls', async () => {
  const response=deferred(), events=[];
  const server=http(async () => {await response.promise; return {value:refWire('Party','9007199254740993')};});
  let model;
  const Source=runtime.component(() => runtime.mapHook(value => {model=value; return null;}, program['DomainBrowser.hostForm'](shell(server.interpreter, context({events})))), {name:'DomainFormTest'});
  const mountedView=await mounted(() => runtime.element(Source, {}));
  const binding = () => model.fields[0].fields[1];
  try {
    await React.act(() => runAction(binding().fields[1](program['DomainBrowser.hostRaw']('', '', 'local date', 'public'))));
    await React.act(() => runAction(model.fields[3]));
    assert.equal(server.requests.length, 0);
    const draft=model.fields[0].fields[0];
    assert.equal(draft.fields[1].tag, 'Except.error');
    const errors=draft.fields[1].fields[0];
    assert.ok(array(errors.fields[1]).length >= 1, 'independent fields accumulate');
    assert.equal(json.fromLean(binding().fields[0]).date, 'local date');
    await React.act(() => runAction(binding().fields[1](program['DomainBrowser.hostRaw'](' Dinner ', '', '9007199254740993', 'public'))));
    let pending;
    await React.act(async () => {pending=runAction(model.fields[3]); await runAction(model.fields[3]);});
    assert.equal(server.requests.length, 1);
    assert.equal(model.fields[1].tag, 'Bool.true');
    assert.deepEqual(server.requests[0].request.input.date, formatRfc3339(9007199254740993n));
    assert.equal(server.requests[0].request.input.title, 'Dinner');
    assert.ok(!Object.hasOwn(server.requests[0].request.input, 'actor'));
    assert.ok(!Object.hasOwn(server.requests[0].request.input, 'now'));
    await React.act(async () => {response.resolve(); await pending;});
    assert.equal(model.fields[1].tag, 'Bool.false');
    assert.deepEqual(events, [['navigate','/parties/9007199254740993']]);
  } finally {await mountedView.close();}
});

test('typed scalar editors support renamed fields, optional Text, four enum choices and a nonfirst default', async () => {
  const never=http(async () => {throw new Error('invalid draft submitted');});
  const Source=runtime.component(() => program['DomainBrowser.renamedFormView'](shell(never.interpreter)), {name:'RenamedEditors'});
  const mountedView=await mounted(() => runtime.element(Source, {}));
  try {
    const {container}=mountedView;
    assert.equal(container.querySelector('[name="secret"]').type, 'password');
    assert.equal(container.querySelector('[name="mailbox"]').type, 'email');
    assert.equal(container.querySelector('[name="notes"]').required, false);
    const choice=container.querySelector('[name="visibility"]');
    assert.equal(choice.options.length, 4); assert.equal(choice.value, 'hostsOnly');
    assert.equal(container.querySelector('label[for="domain-field-secret"]').textContent, 'Secret');
    await submit(container); assert.equal(never.requests.length, 0);
    assert.ok(container.querySelector('[role="alert"]'));
  } finally {await mountedView.close();}
});

test('duplicate-email errors bind the actual field and authentication is established before success navigation', async () => {
  let reject=true, authenticated=false; const events=[];
  // The decision-5 envelope: `{"error": "emailTaken"}` / `{"ok": 1}`.
  const server=http(async () => reject
    ? {status:422, body:{error:'emailTaken'}}
    : {body:{ok:1}});
  const Source=runtime.component(() => program['DomainBrowser.signUpView'](shell(server.interpreter, context({events, authenticated:()=>{authenticated=true;}}))), {name:'SignUp'});
  const mountedView=await mounted(() => runtime.element(Source, {}));
  try {
    await setInput(mountedView.container,'name','Alice');
    await setInput(mountedView.container,'email',' ALICE@Example.COM ');
    await setInput(mountedView.container,'password','Fictional password');
    await submit(mountedView.container);
    assert.equal(server.requests.length, 1);
    assert.equal(server.requests[0].request.input.email, 'alice@example.com');
    assert.match(mountedView.container.textContent, /email: This email already has an account/);
    assert.equal(authenticated, false);
    reject=false; await submit(mountedView.container);
    assert.equal(authenticated, true);
    assert.deepEqual(events, [['authenticated'],['navigate','/parties/new']]);
  } finally {await mountedView.close();}
});

const pageWire=(guests, visibility='public') => ({title:'Fixture party', date:'1970-01-01T00:03:20Z', description:'', visibility:{tag:visibility,value:null}, guests});
const screenProps=(actor, generation=0n, policy=0n, events=[]) => make('LeanReact.Domain.ScreenProps.mk', {
  shell:context({generation, events}), route:'1', actor, policyGeneration:policy,
});
const person=key => ctor('Option.some', [ok(program['DomainBrowser.personRef'](key))]);

test('compiled screen discards visible data after privacy refresh and ignores old actor generations', async () => {
  const old=deferred(); let calls=0;
  const server=http(async () => {
    calls++;
    if(calls===1) {await old.promise; return {value:pageWire({tag:'visible',value:[{name:'Old Alice'}]})};}
    if(calls===2 || calls===4) return {value:pageWire({tag:'hidden',value:null}, 'private')};
    return {value:pageWire({tag:'visible',value:[{name:'Current Bob'}]})};
  });
  const descriptor=program['DomainBrowser.partyComponent'](server.interpreter);
  const render=props => mountElement(descriptor, props);
  const mountedView=await mounted(() => render(screenProps(person('1'))));
  try {
    await mountedView.render(() => render(screenProps(person('2'),1n,1n)));
    assert.match(mountedView.container.textContent, /The guest list is private/);
    assert.ok(!mountedView.container.textContent.includes('Old Alice'));
    await React.act(async () => {old.resolve(); await old.promise;});
    assert.ok(!mountedView.container.textContent.includes('Old Alice'));
    await mountedView.render(() => render(screenProps(person('2'),1n,2n)));
    assert.match(mountedView.container.textContent, /Current Bob/);
    await mountedView.render(() => render(screenProps(none,2n,3n)));
    assert.equal(server.requests.length, 4, 'logout starts an independent nominal scope');
    assert.match(mountedView.container.textContent,/The guest list is private/);
    assert.ok(!mountedView.container.textContent.includes('Current Bob'));
  } finally {await mountedView.close();}
});

test('framework session expiry and network errors remain typed shared channels', async () => {
  for(const [kind, body] of [['unauthenticated', {tag:'unauthenticated'}], ['unauthenticated', {error:'unauthorized'}], ['transport', null]]) {
    const events=[];
    const server=http(async request => {
      if(kind==='transport') throw new TypeError('simulated network failure');
      return {status:401,body};
    });
    const descriptor=program['DomainBrowser.partyComponent'](server.interpreter);
    const mountedView=await mounted(() => mountElement(descriptor, screenProps(none,0n,0n,events)));
    try {
      assert.match(mountedView.container.textContent, /Unable to load/);
      const failure=events.find(event => event[0]==='framework'); assert.ok(failure);
      assert.equal(failure[1].tag, `Contract.CallError.${kind}`);
    } finally {await mountedView.close();}
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
  const server=http(async () => ({value:refWire('Party')}));
  const Source=runtime.component(() => program['DomainBrowser.hostFormView'](shell(server.interpreter)),{name:'UTCEditor'});
  const view=await mounted(() => runtime.element(Source,{}));
  try {
    assert.equal(view.container.querySelector('[name="date"]').type,'datetime-local');
    assert.equal(view.container.querySelector('[name="date"]').getAttribute('aria-label'),'Date (UTC)');
    await setInput(view.container,'title','UTC party');
    await setInput(view.container,'date','2000-02-29T12:34:56');
    await submit(view.container);
    assert.equal(server.requests.length,1);
    assert.deepEqual(server.requests[0].request.input.date,'2000-02-29T12:34:56Z');
  } finally {await view.close();}
});

test('bad credentials use the explicit notice without authentication or navigation', async () => {
  const events=[];
  const server=http(async request => ({status:422,body:{operation:request.operation,tag:'domainError',value:{tag:'invalidCredentials',value:null}}}));
  const Source=runtime.component(() => program['DomainBrowser.signInView'](shell(server.interpreter,context({events}))),{name:'SignIn'});
  const view=await mounted(() => runtime.element(Source,{}));
  try {
    await setInput(view.container,'email','bob@example.test');
    await setInput(view.container,'password','Fictional password');
    await submit(view.container);
    assert.equal(server.requests.length,1);
    assert.match(view.container.textContent,/Check your email and password/);
    assert.deepEqual(events,[]);
  } finally {await view.close();}
});

test('bound action forms refresh RSVP, present host/date failures, and redirect cancellation', async () => {
  const cases=[
    {name:'rsvp',error:null,fill:[],event:['refresh']},
    {name:'edit',error:'hostOnly',fill:[['title','Edited title']],message:'Only the host can edit'},
    {name:'reschedule',error:'partyStarted',fill:[['date','2026-10-01T00:00']],message:'A party that has started cannot be rescheduled'},
    {name:'reschedule',error:'dateMustBeFuture',fill:[['date','2026-10-01T00:00']],message:'date: Choose a future date'},
    {name:'cancel',error:null,fill:[],event:['navigate','/parties/new']},
  ];
  for(const item of cases) {
    const events=[];
    const server=http(async request => request.operation.name==='partyPage' ? {value:pageWire({tag:'hidden',value:null},'private')} : item.error ? {status:422,body:{operation:request.operation,tag:'domainError',value:{tag:item.error,value:null}}} : {value:null});
    const descriptor=program['DomainBrowser.partyComponent'](server.interpreter);
    const view=await mounted(() => mountElement(descriptor,screenProps(person('1'),0n,0n,events)));
    try {
      assert.equal(view.container.querySelector('[name="id"]'),null);
      for(const [field,value] of item.fill) await setInput(view.container,field,value);
      const index={rsvp:0,edit:1,reschedule:2,cancel:3}[item.name];
      await React.act(() => view.container.querySelectorAll('form')[index].dispatchEvent(new window.Event('submit',{bubbles:true,cancelable:true})));
      const requests=server.requests.filter(request => request.request.operation.name===item.name);
      assert.equal(requests.length,1,item.name);
      assert.deepEqual(requests[0].request.input.id,sentRef());
      if(item.message) {assert.match(view.container.textContent,new RegExp(item.message)); assert.deepEqual(events,[]);}
      if(item.event?.[0]==='refresh') {assert.equal(server.requests.filter(request => request.request.operation.name==='partyPage').length,2); assert.deepEqual(events,[]);}
      else if(item.event) assert.deepEqual(events,[item.event]);
    } finally {await view.close();}
  }
});

test('every visibility/actor row traverses real Flow output, HTTP codecs, exact bytes and the compiled screen', async () => {
  const cases=JSON.parse(await readFile(new URL('./generated/matrix.json',import.meta.url),'utf8'));
  assert.equal(cases.length,12);
  for(const item of cases) {
    const visibility=item.visibility;
    const allowed=visibility==='public' || (visibility==='attendees' && item.actorLabel==='attendee');
    assert.equal(typeof item.value.guests === 'string' ? item.value.guests : item.value.guests.tag,allowed ? 'visible' : 'hidden',`${visibility}/${item.actorLabel}`);
    assert.equal(item.projectionReads,allowed ? 1 : 0,'denial does not execute projection');
    const bytes=JSON.stringify(item.value.guests);
    if(!allowed) {
      assert.equal(bytes,'"hidden"');
      for(const secret of ['Alice','Bob','Carol','email','key','count','total']) assert.ok(!bytes.includes(secret));
    } else assert.deepEqual(item.value.guests.value,[{name:'Guest Bob'}]);
    const server=http(async () => ({value:item.value}));
    const descriptor=program['DomainBrowser.partyComponent'](server.interpreter);
    const actor=item.actor===null ? none : person(String(item.actor));
    const view=await mounted(() => mountElement(descriptor,screenProps(actor)));
    try {
      assert.equal(server.requests.length,1);
      assert.equal(view.container.textContent.includes('Guest Bob'),allowed);
      assert.equal(view.container.textContent.includes('The guest list is private'),!allowed);
      assert.ok(!view.container.textContent.includes('@example.test'));
      assert.deepEqual(server.requests[0].request.input,{id:item.reference});
    } finally {await view.close();}
  }
});

test('successful RSVP and host privacy edits refresh and replace the entire disclosure', async () => {
  for(const initial of ['public','attendees']) {
    let pageCalls=0, privateNow=false;
    const server=http(async request => {
      if(request.operation.name==='partyPage') {
        pageCalls++;
        return {value:pageWire(privateNow ? {tag:'hidden',value:null} : {tag:'visible',value:[{name:'Current Bob'}]},privateNow ? 'private' : initial)};
      }
      if(request.operation.name==='edit') privateNow=true;
      return {value:null};
    });
    const descriptor=program['DomainBrowser.partyComponent'](server.interpreter);
    const view=await mounted(() => mountElement(descriptor,screenProps(person('1'))));
    try {
      assert.match(view.container.textContent,/Current Bob/);
      const forms=view.container.querySelectorAll('form');
      await React.act(() => forms[0].dispatchEvent(new window.Event('submit',{bubbles:true,cancelable:true})));
      assert.equal(pageCalls,2,'RSVP refreshes the current screen');
      await setInput(view.container,'title','Private party');
      await setInput(view.container,'visibility','private');
      await React.act(() => forms[1].dispatchEvent(new window.Event('submit',{bubbles:true,cancelable:true})));
      assert.equal(pageCalls,3,'privacy edit refreshes the current screen');
      assert.match(view.container.textContent,/The guest list is private/);
      assert.ok(!view.container.textContent.includes('Current Bob'));
    } finally {await view.close();}
  }
});

test('cancelled and unmounted submissions cannot navigate when old responses settle', async () => {
  for(const mode of ['cancel','unmount']) {
    const response=deferred(),events=[];
    const server=http(async () => {await response.promise; return {value:refWire('Party')};});
    let model;
    const Source=runtime.component(() => runtime.mapHook(value => {model=value;return null;},program['DomainBrowser.hostForm'](shell(server.interpreter,context({events})))),{name:`Lifetime-${mode}`});
    const view=await mounted(() => runtime.element(Source,{}));
    let closed=false;
    try {
      await React.act(() => runAction(model.fields[0].fields[1].fields[1](program['DomainBrowser.hostRaw']('Valid party','','200','public'))));
      let pending;
      await React.act(() => {pending=runAction(model.fields[3]);});
      assert.equal(server.requests.length,1);
      if(mode==='cancel') {
        await React.act(() => runAction(model.fields[6]));
        assert.equal(model.fields[1].tag,'Bool.false');
      } else {await view.close();closed=true;}
      await React.act(async () => {response.resolve();await pending;});
      assert.deepEqual(events,[]);
    } finally {if(!closed) await view.close();}
  }
});

test('request-scoped transport aborts an active submit on cancellation and unmount', async () => {
  for(const mode of ['cancel','unmount']) {
    const started=deferred(),events=[]; let signal;
    const client=generated.createClient({fetch: async (_url,init) => {
      signal=init.signal; started.resolve();
      await new Promise((_,reject) => {signal.addEventListener('abort',() => reject(new DOMException('Cancelled','AbortError')),{once:true});});
    }});
    const base=createContractInterpreter({program,client});
    const factory=request => createContractInterpreter({program,client,request});
    let model;
    const Source=runtime.component(() => runtime.mapHook(value => {model=value;return null;},program['DomainBrowser.hostForm'](shell(base,context({events}),ctor('Option.some',[factory])))),{name:`Transport-${mode}`});
    const view=await mounted(() => runtime.element(Source,{}));let closed=false;
    try {
      await React.act(() => runAction(model.fields[0].fields[1].fields[1](program['DomainBrowser.hostRaw']('Valid party','','200','public'))));
      let pending;
      await React.act(async () => {pending=runAction(model.fields[3]);await started.promise;});
      assert.ok(signal instanceof AbortSignal);assert.equal(signal.aborted,false);
      if(mode==='cancel') await React.act(() => runAction(model.fields[6]));
      else {await view.close();closed=true;}
      await React.act(async () => {await pending;});
      assert.equal(signal.aborted,true);
      assert.deepEqual(events,[]);
    } finally {if(!closed) await view.close();}
  }
});

test('request-scoped query transport aborts obsolete actor generations and unmount', async () => {
  const signals=[];
  const client=generated.createClient({fetch: async (_url,init) => {
    signals.push(init.signal);
    await new Promise((_,reject) => init.signal.addEventListener('abort',() => reject(new DOMException('Cancelled','AbortError')),{once:true}));
  }});
  const base=createContractInterpreter({program,client});
  const factory=request => createContractInterpreter({program,client,request});
  const descriptor=program['DomainBrowser.partyComponentWithRequests'](base,factory);
  const events=[];
  const view=await mounted(() => mountElement(descriptor,screenProps(person('1'),0n,0n,events)));
  let closed=false;
  try {
    assert.equal(signals.length,1);assert.equal(signals[0].aborted,false);
    await view.render(() => mountElement(descriptor,screenProps(person('2'),1n,1n,events)));
    assert.equal(signals.length,2);assert.equal(signals[0].aborted,true);assert.equal(signals[1].aborted,false);
    await view.close();closed=true;
    assert.equal(signals[1].aborted,true);assert.deepEqual(events,[]);
  } finally {if(!closed) await view.close();}
});

test('an old cancelled reply cannot release or abort a newer submission', async () => {
  const first=deferred(),second=deferred(),events=[],signals=[];
  const server=http(async (_request,index) => {
    await (index===1 ? first.promise : second.promise);
    return index===1 ? {value:legacyRef('Party','1')} : {body:{ok:2}};
  });
  const original=server.client;
  const client={...original,call:async (id,input,options) => {signals.push(options.signal);return original.call(id,input,options);}};
  const base=createContractInterpreter({program,client});
  const factory=request => createContractInterpreter({program,client,request});
  let model;
  const Source=runtime.component(() => runtime.mapHook(value => {model=value;return null;},program['DomainBrowser.hostForm'](shell(base,context({events}),ctor('Option.some',[factory])))),{name:'Resubmit'});
  const view=await mounted(() => runtime.element(Source,{}));
  try {
    await React.act(() => runAction(model.fields[0].fields[1].fields[1](program['DomainBrowser.hostRaw']('Valid party','','200','public'))));
    let oldPending,newPending;
    await React.act(() => {oldPending=runAction(model.fields[3]);});
    await React.act(() => runAction(model.fields[6]));
    await React.act(() => {newPending=runAction(model.fields[3]);});
    assert.equal(server.requests.length,2);assert.equal(signals[0].aborted,true);assert.equal(signals[1].aborted,false);
    await React.act(async () => {first.resolve();await oldPending;});
    assert.equal(model.fields[1].tag,'Bool.true');assert.equal(signals[1].aborted,false);assert.deepEqual(events,[]);
    await React.act(async () => {second.resolve();await newPending;});
    assert.equal(model.fields[1].tag,'Bool.false');assert.deepEqual(events,[['navigate','/parties/2']]);
  } finally {first.resolve();second.resolve();await view.close();}
});
