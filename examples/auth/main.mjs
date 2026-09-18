import React, { useEffect, useRef, useState, useSyncExternalStore } from 'react';
import { createRoot } from 'react-dom/client';
import { createAuthClient } from '../../engine/LeanApp/AuthClient.mjs';

const client = createAuthClient();
const messages = {
  'auth.invalid_credentials': 'The username or password is incorrect.',
  'auth.username_unavailable': 'That username is unavailable. Choose another.',
  'auth.invalid_username': 'Use 3–32 letters, numbers, underscores, or hyphens.',
  'auth.invalid_password': 'Use 15–128 characters and at most 1024 UTF-8 bytes.',
  'auth.required': 'Please log in to continue.',
  'auth.forbidden': 'This request is not permitted. Please log in again.',
  'auth.throttled': 'Too many attempts. Please wait before trying again.',
  'auth.unavailable': 'The service is unavailable. Please try again later.',
  'auth.session_not_found': 'That session is already gone.',
};
const message = error => messages[error.code] ?? 'The request could not be completed. Please try again.';

function App() {
  const auth = useSyncExternalStore(client.subscribe, client.getSnapshot);
  const [mode, setMode] = useState('login');
  const [notice, setNotice] = useState('');
  const [result, setResult] = useState(null);
  const [checking, setChecking] = useState(false);
  const [sessions, setSessions] = useState(null);
  const form = useRef(null);
  useEffect(() => { client.restore().catch(e => { if (e.code !== 'auth.required' && e.code !== 'auth.stale') setNotice(message(e)); }); }, []);
  useEffect(() => { if (!auth.user) setSessions(null); }, [auth.user]);
  async function guarded(action) {
    const owner = auth.epoch;
    try { await action(); }
    catch (e) { if (client.getSnapshot().epoch === owner && e.code !== 'auth.stale') setNotice(message(e)); }
  }
  const refreshSessions = () => guarded(async () => setSessions(await client.sessions()));
  const revoke = id => guarded(async () => { if (!await client.revokeSession(id)) await refreshSessions(); });
  const logoutAll = () => guarded(async () => { await client.logoutAll(); setNotice('You are signed out everywhere.'); });
  async function submit(event) {
    event.preventDefault();
    const username = form.current.elements.username.value;
    let password = form.current.elements.password.value;
    form.current.elements.password.value = '';
    setNotice(''); setResult(null);
    if (!/^[A-Za-z0-9_-]{3,32}$/.test(username)) {
      password = ''; setNotice(messages['auth.invalid_username']); form.current.elements.username.focus(); return;
    }
    if ([...password].length < 15 || [...password].length > 128 || new TextEncoder().encode(password).length > 1024) {
      password = ''; setNotice(messages['auth.invalid_password']); form.current.elements.password.focus(); return;
    }
    const pending = client[mode](username, password);
    password = '';
    try { await pending; setNotice(mode === 'signup' ? 'Account created. You are signed in.' : 'You are signed in.'); }
    catch (e) { if (e.code !== 'auth.stale') setNotice(message(e)); }
  }
  async function logout() {
    setResult(null); setNotice('');
    try { await client.logout(); setNotice('You are signed out.'); }
    catch (e) { if (e.code !== 'auth.stale') setNotice(message(e)); }
  }
  async function whoami() {
    const owner = auth.epoch;
    setChecking(true); setResult(null); setNotice('');
    try {
      const value = await client.call('/api/whoami', { operation: { namespace: 'auth-demo', name: 'whoami', version: '1' }, kind: 'query', input: null });
      if (typeof value !== 'string') throw new Error('Invalid response');
      if (client.getSnapshot().epoch === owner) setResult({ owner, value });
    } catch (e) { if (client.getSnapshot().epoch === owner && e.code !== 'auth.stale') setNotice(message(e)); }
    finally { setChecking(false); }
  }
  return <main>
    <h1>Account access</h1>
    <p>Use a username and password to access the protected demo.</p>
    <p role="status" aria-live="polite" className="notice">{auth.transitioning ? 'Updating session…' : notice}</p>
    {auth.user ? <section aria-labelledby="account-heading">
      <h2 id="account-heading">Signed in as {auth.user.username}</h2>
      <button onClick={logout}>Log out</button>
      <h2>Protected request</h2>
      <button onClick={whoami} disabled={checking}>{checking ? 'Checking…' : 'Check who I am'}</button>
      {result?.owner === auth.epoch && <p role="status">Server confirmed: {result.value}</p>}
      <h2>Sessions</h2>
      <p className="hint">Other devices signed in to this account. Revoking one signs it out immediately.</p>
      <button onClick={refreshSessions}>Refresh sessions</button>
      <button onClick={logoutAll}>Sign out everywhere</button>
      {sessions && <ul aria-label="Sessions">{sessions.map(s => <li key={s.id}>
        {s.label ?? 'Unnamed device'}{s.current ? ' (this device)' : ''}
        {' '}<button onClick={() => revoke(s.id)} aria-label={`Revoke ${s.label ?? 'unnamed device'}${s.current ? ' (this device)' : ''}`}>Revoke</button>
      </li>)}</ul>}
    </section> : <section aria-labelledby="form-heading">
      <div className="modes" aria-label="Account action">
        {['login', 'signup'].map(value => <button key={value} type="button" aria-pressed={mode === value} disabled={auth.transitioning}
          onClick={() => { setMode(value); setNotice(''); form.current?.reset(); }}>{value === 'login' ? 'Log in' : 'Sign up'}</button>)}
      </div>
      <h2 id="form-heading">{mode === 'signup' ? 'Create an account' : 'Log in'}</h2>
      <form ref={form} onSubmit={submit} aria-busy={auth.transitioning}>
        <label htmlFor="username">Username</label>
        <input id="username" name="username" autoComplete="username" autoCapitalize="none" spellCheck="false" required
          minLength={3} maxLength={32} pattern="[A-Za-z0-9_\-]{3,32}" aria-describedby="username-help" disabled={auth.transitioning}/>
        <p id="username-help" className="hint">3–32 letters, numbers, underscores, or hyphens. Case does not matter.</p>
        <label htmlFor="password">Password</label>
        <input id="password" name="password" type="password" autoComplete={mode === 'signup' ? 'new-password' : 'current-password'}
          required aria-describedby="password-help" disabled={auth.transitioning}/>
        <p id="password-help" className="hint">15–128 characters, at most 1024 UTF-8 bytes. Spaces are preserved.</p>
        <button type="submit" disabled={auth.transitioning}>{mode === 'signup' ? 'Create account' : 'Log in'}</button>
      </form>
    </section>}
  </main>;
}
createRoot(document.getElementById('root')).render(<App/>);
