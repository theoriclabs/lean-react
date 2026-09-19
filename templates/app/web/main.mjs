// The presentation shell: ordinary React for account state, the Lean screen for the notes.
// Credentials, the title rule and persistence are owned by Lean.
import React, { useState, useSyncExternalStore } from 'react';
import { createRoot } from 'react-dom/client';
import { createAuthClient } from '@leanapp/engine/LeanApp/AuthClient.mjs';
import { action } from '@leanapp/engine/runtime/actions.mjs';
import { ctor, mountElement } from '@leanapp/engine/adapters/leanjs-react.mjs';
import * as app from './generated/app.mjs';
import { operations } from './generated/operations.mjs';

const auth = createAuthClient();
const ok = value => ctor('Except.ok', [value]);
const err = code => ctor('Except.error', [code]);
const noteToLean = note => ctor('{{Name}}.Note.mk', [note.id, note.title]);

/** Authenticated calls go through the auth client (cookie plus CSRF); the generated codecs check
 * the wire shapes on both sides. */
async function invoke(name, input) {
  const operation = operations[name];
  const value = await auth.call(operation.path, {
    operation: operation.identity, kind: operation.kind, input: operation.encodeInput(input) });
  return operation.decodeOutput(value);
}
const guarded = work => action(async () => {
  try { return ok(await work()); } catch (error) { return err(error?.code ?? 'notes.failed'); }
});
// `{{Name}}.NoteService Action`: `list` is an Action, `add` takes the Lean `Title` (its one field is the string).
const service = ctor('{{Name}}.NoteService.mk', [
  guarded(async () => (await invoke('list', null)).map(noteToLean)),
  title => guarded(async () => noteToLean(await invoke('add', title.fields[0]))),
]);

function Account() {
  const session = useSyncExternalStore(auth.subscribe, auth.getSnapshot);
  const [mode, setMode] = useState('login');
  const [error, setError] = useState('');
  async function submit(event) {
    event.preventDefault();
    const form = event.currentTarget;
    const username = form.elements.username.value;
    const password = form.elements.password.value;
    form.elements.password.value = '';
    setError('');
    try { await auth[mode](username, password); } catch (cause) { setError(cause?.code ?? 'auth.failed'); }
  }
  if (session.user) return <header className="bar">
    <span>Signed in as <strong>{session.user.username}</strong></span>
    <button type="button" onClick={() => auth.logout().catch(() => {})}>Log out</button>
  </header>;
  return <form className="account" onSubmit={submit}>
    <h1>{{Name}}</h1>
    <label>Username<input name="username" autoComplete="username" required /></label>
    <label>Password<input name="password" type="password" minLength={15}
      autoComplete={mode === 'signup' ? 'new-password' : 'current-password'} required /></label>
    <div className="controls">
      <button type="submit">{mode === 'signup' ? 'Create account' : 'Log in'}</button>
      <button type="button" onClick={() => setMode(mode === 'signup' ? 'login' : 'signup')}>
        {mode === 'signup' ? 'I already have an account' : 'Sign up instead'}
      </button>
    </div>
    {error && <p role="alert">{error}</p>}
  </form>;
}

function Shell() {
  const session = useSyncExternalStore(auth.subscribe, auth.getSnapshot);
  return <>
    <Account />
    {session.user && <main key={session.epoch}>
      {mountElement(app['{{Name}}.UI.App'], ctor('{{Name}}.UI.AppProps.mk', [service]))}
    </main>}
  </>;
}

auth.restore().catch(() => {});
createRoot(document.getElementById('root')).render(<React.StrictMode><Shell /></React.StrictMode>);
