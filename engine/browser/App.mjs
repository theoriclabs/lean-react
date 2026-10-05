// The browser entry of a full-stack app (`app% Name where app := X`, `LeanReact.Server`):
// mounts the compiled `App.component X` over the generated route client. Staged next to
// `domain.mjs` (LeanJS), `operations.mjs` and `pages.json` (the app's emit step) and the
// runtime, then bundled into `app.mjs` (see scripts/browser-target.py).
import React, {useSyncExternalStore} from 'react';
import {createRoot} from 'react-dom/client';
import * as program from './domain.mjs';
import {createClient} from './operations.mjs';
import assembly from './pages.json' with {type: 'json'};
import {action} from './runtime/actions.mjs';
import {mountElement, ctor} from './runtime/leanjs-react.mjs';
import {createContractInterpreter} from './runtime/leanjs-contract.mjs';

const unit = ctor('PUnit.unit');
const none = ctor('Option.none');
const identityKey = value => JSON.stringify([value.namespace, value.name, value.version]);

export function readCookie(name, document = globalThis.document) {
  const entries = document.cookie.split(';').map(value => value.trim().split('='));
  const matching = entries.filter(parts => parts[0] === name);
  return matching.length === 1 && matching[0].length === 2 ? matching[0][1] : '';
}

/** The route-client transport: every request but a GET carries the CSRF header, read from
its cookie at send time. */
export function routeFetch(fetchImpl, csrfName, document = globalThis.document) {
  return (url, init = {}) => {
    const headers = new Headers(init.headers);
    if ((init.method ?? 'GET').toUpperCase() !== 'GET') {
      const csrf = readCookie(csrfName, document);
      if (csrf) headers.set('x-csrf-token', csrf);
    }
    return fetchImpl(url, {...init, headers});
  };
}

/** A LeanReact `App` (pages.json `app`): its compiled `App.component` routes every page from
the location. The host owns what a document owns: the location, the auth generation, the
signed-in actor (the profile reference as text) and the shared failure channel. */
export function mountDomainApp({root = document.getElementById('root'),
    bootstrap = JSON.parse(document.getElementById('leanapp-bootstrap').textContent),
    fetchImpl = globalThis.fetch, baseURL = '', window = globalThis.window} = {}) {
  const document = window.document;
  const listeners = new Set();
  const refKey = wire => (typeof wire === 'object' && wire !== null && 'key' in wire) ? String(wire.key) : String(wire);
  const actorOf = wire => (wire === null || wire === undefined) ? none : ctor('Option.some', [refKey(wire)]);
  const here = () => window.location.pathname + window.location.search;
  let snapshot = Object.freeze({generation: 0n, actor: actorOf(bootstrap.actor), path: here(), failure: ''});
  let csrf = readCookie(bootstrap.csrfCookie, document), pending = null;
  const update = changes => {
    snapshot = Object.freeze({...snapshot, ...changes});
    listeners.forEach(listener => listener());
  };
  // A changed or cleared CSRF cookie (sign-out, another tab) is a new auth generation.
  const checkCookie = () => {
    const next = readCookie(bootstrap.csrfCookie, document);
    if (next !== csrf && next !== pending?.csrf) {
      csrf = next;
      pending = null;
      update({generation: snapshot.generation + 1n, actor: none});
    }
    return snapshot.generation;
  };
  const generated = createClient({baseURL, fetch: routeFetch(fetchImpl, bootstrap.csrfCookie, document)});
  const authentication = new Set(assembly.authentication.map(identityKey));
  const client = {...generated, async call(identity, input, options) {
    if (!authentication.has(identityKey(identity))) return generated.call(identity, input, options);
    const generation = snapshot.generation;
    let responseCSRF = '';
    // Per call: the session this response committed, tied to its own typed result.
    const authClient = createClient({baseURL, fetch: routeFetch(async (url, init) => {
      const response = await fetchImpl(url, init);
      responseCSRF = response.headers.get('x-leanapp-auth-csrf') ?? '';
      return response;
    }, bootstrap.csrfCookie, document)});
    const result = await authClient.call(identity, input, options);
    if (result.ok && responseCSRF && responseCSRF === readCookie(bootstrap.csrfCookie, document)) {
      const change = {actor: actorOf(result.value), csrf: responseCSRF};
      if (generation !== snapshot.generation) {
        csrf = responseCSRF; pending = null;
        update({actor: change.actor, generation: snapshot.generation + 1n});
      } else {
        // Applied by the app's authenticationChanged, after the form's own success.
        pending = change;
        window.setTimeout(() => {
          if (pending === change) {
            pending = null;
            if (readCookie(bootstrap.csrfCookie, document) === change.csrf) {
              csrf = change.csrf;
              update({actor: change.actor, generation: snapshot.generation + 1n});
            } else checkCookie();
          }
        }, 0);
      }
    } else if (result.ok) {
      checkCookie();
    }
    return result;
  }};
  const interpreter = createContractInterpreter({program, client});
  const requestClient = request => createContractInterpreter({program, client, request});
  const component = program[assembly.app.component](interpreter)(requestClient);
  const navigate = path => {
    window.history.pushState({}, '', path);
    update({path: here(), failure: ''});
  };
  const authChanged = () => {
    if (!pending) { checkCookie(); return; }
    csrf = pending.csrf;
    update({actor: pending.actor, generation: snapshot.generation + 1n, failure: ''});
    pending = null;
  };
  const framework = error => {
    if (error.tag === 'Contract.CallError.unauthenticated') {
      const hadAuthority = snapshot.actor.tag === 'Option.some' || pending !== null;
      pending = null;
      update({generation: snapshot.generation + (hadAuthority ? 1n : 0n), actor: none, failure: 'Please sign in.'});
    } else update({failure: 'Unable to complete. Try again.'});
  };
  function Root() {
    const state = useSyncExternalStore(listener => {listeners.add(listener); return () => listeners.delete(listener);},
      () => snapshot);
    const shell = program[assembly.app.shell](state.generation, action(checkCookie),
      error => action(() => {framework(error); return unit;}),
      path => action(() => {navigate(path); return unit;}),
      action(() => {authChanged(); return unit;}));
    return React.createElement(React.Fragment, null,
      state.failure && React.createElement('p', {role: 'alert'}, state.failure),
      mountElement(component, program[assembly.app.props](shell, state.path, state.actor)));
  }
  const popstate = () => update({path: here(), failure: ''});
  window.addEventListener('popstate', popstate);
  window.addEventListener('focus', checkCookie);
  const poll = window.setInterval(checkCookie, 250);
  const reactRoot = createRoot(root);
  reactRoot.render(React.createElement(Root));
  return {client, navigate, snapshot: () => snapshot, checkCookie,
    close() {window.clearInterval(poll); window.removeEventListener('focus', checkCookie);
      window.removeEventListener('popstate', popstate); reactRoot.unmount();}};
}

if (globalThis.document?.getElementById('leanapp-bootstrap')) mountDomainApp();
