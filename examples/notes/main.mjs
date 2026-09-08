import React, { useEffect, useRef, useState, useSyncExternalStore } from 'react';
import { createRoot } from 'react-dom/client';
import { createAuthClient } from '../../engine/LeanApp/AuthClient.mjs';

const auth = createAuthClient();
const empty = { search: '', id: null, offset: '0', limit: '50' };
const errors = {
  'auth.invalid_credentials': 'That username and password did not match.',
  'auth.username_unavailable': 'That username is taken. Try another.',
  'auth.invalid_username': 'Use 3–32 letters, numbers, underscores or hyphens.',
  'auth.invalid_password': 'Use a disposable password with 15–128 characters.',
  'auth.throttled': 'The demo is busy. Please try again in a minute.',
  'auth.required': 'Please sign in again.',
  'auth.unavailable': 'The server could not be reached. Please try again.',
};
const message = e => errors[e?.code] ?? 'The request could not be completed safely. Please try again.';
const isObject = x => x && typeof x === 'object' && !Array.isArray(x);
function answer(x) {
  if (!isObject(x) || !Array.isArray(x.notes) || typeof x.count !== 'string' || !/^\d+$/.test(x.count) ||
      typeof x.notFound !== 'boolean' || typeof x.tooMany !== 'boolean' ||
      x.notes.some(n => !isObject(n) || typeof n.id !== 'string' || !/^\d+$/.test(n.id) ||
        typeof n.title !== 'string' || typeof n.body !== 'string')) throw new Error('Invalid notes response');
  return x;
}
async function call(name, input = empty) {
  const result = await auth.call(`/api/notes/${name}`, {
    operation: { namespace: 'notes', name, version: '1' }, kind: name === 'lab' ? 'command' : 'query',
    input: name === 'lab' ? null : input,
  });
  if (name !== 'lab') return answer(result);
  if (!isObject(result) || !['foreignId', 'archiveId'].every(k => typeof result[k] === 'string' && /^\d+$/.test(result[k])))
    throw new Error('Invalid fixture response');
  return result;
}

function Account() {
  const [mode, setMode] = useState('signup'), [error, setError] = useState('');
  const [busy, setBusy] = useState(false);
  const form = useRef(null);
  async function submit(event) {
    event.preventDefault(); setBusy(true); setError('');
    const username = form.current.elements.username.value;
    let password = form.current.elements.password.value;
    form.current.elements.password.value = '';
    const pending = auth[mode](username, password); password = '';
    try { await pending; } catch (e) { setError(message(e)); } finally { setBusy(false); }
  }
  return <section className="card account"><p className="eyebrow">01 / YOUR OWN TEST WORKSPACE</p>
    <h2>{mode === 'signup' ? 'Try it with your own account.' : 'Welcome back.'}</h2>
    <p>We’ll create four synthetic notes for you. Two are yours to read. Two test the boundaries.</p>
    <form ref={form} onSubmit={submit}>
      <label htmlFor="username">Username</label><input id="username" name="username" autoComplete="username" minLength="3" maxLength="32" pattern="[A-Za-z0-9_-]+" required placeholder="e.g. curious_builder" disabled={busy}/>
      <label htmlFor="password">Disposable password</label><input id="password" name="password" type="password" autoComplete={mode === 'signup' ? 'new-password' : 'current-password'} minLength="15" maxLength="128" required placeholder="At least 15 characters" disabled={busy}/>
      <p className="fine">Synthetic demo only. Please do not reuse a real password. No account recovery.</p>
      {error && <p role="alert" className="error">{error}</p>}
      <button className="primary" disabled={busy}>{busy ? 'Connecting…' : mode === 'signup' ? 'Create my test workspace →' : 'Log in →'}</button>
    </form>
    <button className="text-button" disabled={busy} onClick={() => { form.current.reset(); setError(''); setMode(mode === 'signup' ? 'login' : 'signup'); }}>
      {mode === 'signup' ? 'Already have an account? Log in' : 'Create a new account'}</button>
  </section>;
}

function Workspace({ user }) {
  const [data, setData] = useState(null), [lab, setLab] = useState(null), [query, setQuery] = useState('');
  const [status, setStatus] = useState('Preparing your private fixture…'), [failure, setFailure] = useState('');
  const [busy, setBusy] = useState(true), [probe, setProbe] = useState('');
  const requestEpoch = useRef(0);
  useEffect(() => {
    let current = true;
    (async () => {
      try {
        const lab = await call('lab'); const result = await call('list');
        if (current) { setLab(lab); setData(result); setStatus('Your two visible notes are ready.'); }
      } catch (e) { if (current) { setFailure(message(e)); setStatus(''); } }
      finally { if (current) setBusy(false); }
    })();
    return () => { current = false; };
  }, []);
  async function search(event) {
    event.preventDefault(); const epoch = ++requestEpoch.current; setBusy(true); setFailure('');
    try {
      const result = await call('search', { ...empty, search: query });
      if (epoch === requestEpoch.current) { setData(result); setStatus(`${result.count} authorized match${result.count === '1' ? '' : 'es'}.`); }
    } catch (e) { setFailure(message(e)); } finally { setBusy(false); }
  }
  async function inspect(id, label) {
    setBusy(true); setFailure(''); setProbe('');
    try { const result = await call('lookup', { ...empty, id }); setProbe(`${label}: ${result.notes[0]?.title ?? 'No note returned'}`); }
    catch (e) { if (e.status === 404) setProbe(`${label} → 404 · notes.not_found. No note body was returned.`); else setFailure(message(e)); }
    finally { setBusy(false); }
  }
  async function exportNotes() {
    setBusy(true); setFailure('');
    try {
      const result = await call('export', { ...empty, search: query });
      const url = URL.createObjectURL(new Blob([JSON.stringify(result.notes, null, 2)], { type: 'application/json' }));
      const link = document.createElement('a'); link.href = url; link.download = 'my-private-notes.json'; link.click();
      setTimeout(() => URL.revokeObjectURL(url), 1000); setStatus(`Exported ${result.count} authorized notes.`);
    } catch (e) { setFailure(message(e)); } finally { setBusy(false); }
  }
  return <div className="workspace"><section className="card collection">
    <div className="section-top"><div><p className="eyebrow">YOUR PRIVATE COLLECTION</p><h2>{user.username}’s notes</h2></div><span className="pill">{data?.count ?? '—'} visible</span></div>
    <form className="search" onSubmit={search}><label className="sr-only" htmlFor="search">Search your notes</label><input id="search" placeholder="Search titles, e.g. budget" value={query} maxLength="100" onChange={e => setQuery(e.target.value)}/><button disabled={busy}>Search</button></form>
    <div className="notes">{data?.notes.map(n => <article className="note" key={n.id}><span className="note-id">NOTE / {n.id}</span><h3>{n.title}</h3><p>{n.body}</p><span className="owned">✓ Owner and tenant match</span></article>)}
      {data?.notes.length === 0 && <p className="empty">No authorized notes match this title.</p>}</div>
    <div className="collection-footer"><p role="status">{status}</p><button className="secondary" disabled={busy || !data} onClick={exportNotes}>Export JSON ↗</button></div>
    {failure && <p role="alert" className="error">{failure}</p>}
  </section><section className="card probes"><p className="eyebrow">02 / CALL THE API DIRECTLY</p><h2>Knowing an ID grants nothing.</h2>
    <p>These synthetic decoys belong to your test fixture. Their IDs are intentionally disclosed for this exercise; their bodies are outside your read scope.</p>
    <div className="probe-buttons"><button disabled={busy || !lab} onClick={() => inspect(lab.foreignId, 'Other owner, same tenant')}>Read another owner’s note</button>
      <button disabled={busy || !lab} onClick={() => inspect(lab.archiveId, 'Same owner, other tenant')}>Read your archived-tenant note</button>
      <button disabled={busy || !lab} onClick={() => inspect('9223372036854775807', 'Missing note')}>Read a nonexistent note</button></div>
    <p className="probe-result" role="status">{probe || 'Choose a request. Each must produce the same not-found response.'}</p>
    <p className="fine">A missing and an inaccessible note have the same status and body. Equal response timing is not claimed.</p>
  </section></div>;
}

function PolicyCard() {
  return <aside className="policy"><p className="eyebrow">THE RULE, ONCE</p><h2>Authorization is part of the function’s contract.</h2>
    <pre><code>{`CanRead session caller note :=\n  SessionValid session caller\n  ∧ note.owner = caller.actor\n  ∧ note.tenant = caller.tenant`}</code></pre>
    <div className="flow"><span>Authenticated request</span><b>↓</b><span>Checked read grant</span><b>↓</b><span>Scoped SQLite read</span><b>↓</b><span>Certified note rows</span></div>
    <p>Search, count and export use the same scoped relation. A new endpoint has to preserve the policy.</p><a href="/spec.lean" target="_blank" rel="noreferrer">Read the actual specification ↗</a>
  </aside>;
}

function AgentLab({ receipt }) {
  const [selected, setSelected] = useState('drop-owner');
  const sample = receipt?.examples.find(x => x.id === selected);
  return <section className="agent-lab"><div className="section-top"><div><p className="eyebrow">03 / WHEN AN AGENT GETS IT WRONG</p><h2>“Add export. Preserve the access policy.”</h2></div><span className="pill">Recorded verification</span></div>
    <p className="intro">Inspect a candidate change and the result of checking it. These are reproducible agent-style patches, not a captured autonomous-agent session. No visitor code runs here.</p>
    {!receipt ? <p role="status">Loading the build’s verification evidence…</p> : <div className="agent-grid"><nav aria-label="Candidate patches">{receipt.examples.map(x => <button key={x.id} aria-pressed={selected === x.id} onClick={() => setSelected(x.id)}><span className={x.actual === 'accepted' ? 'dot green' : 'dot orange'}/>{x.title}<span>↗</span></button>)}</nav>
      {sample && <article className="code-card"><div className="code-heading"><span>{sample.stage}</span><strong className={sample.actual === 'accepted' ? 'success-text' : 'rejected'}>{sample.actual === 'accepted' ? '✓ Accepted' : '× Rejected'}</strong></div>
        <pre className="patch"><code>{sample.code}</code></pre><p className="eyebrow diagnostic-title">ACTUAL CHECK OUTPUT</p><pre className="diagnostic"><code>{sample.diagnostic}</code></pre></article>}</div>}
    <div className="boundary-note"><h3>The verifier needs a boundary too.</h3><p>Lean does not stop an agent from editing a file. A failed proof can block release only when the specification, checker and release permissions are controlled outside the agent’s patch. An agent allowed to weaken all three can bypass the intended policy.</p>
      <p>This demo reproduces type/proof rejection, an admitted-proof audit, and a protected-input digest comparison. It does not claim to configure a tamper-proof CI service or sandbox malicious agents.</p></div>
  </section>;
}

function App() {
  const session = useSyncExternalStore(auth.subscribe, auth.getSnapshot);
  const [tab, setTab] = useState('workspace'), [receipt, setReceipt] = useState(null), [receiptError, setReceiptError] = useState(false);
  useEffect(() => { auth.restore().catch(() => {}); fetch('/evidence.json').then(r => { if (!r.ok) throw new Error(); return r.json(); }).then(setReceipt).catch(() => setReceiptError(true)); }, []);
  return <><header><a className="brand" href="#"><span className="brand-mark">∀</span><span>LeanApp <i>/</i> Private Notes</span></a><div className="header-actions"><span className="experimental">EXPERIMENTAL</span>{session.user && <button onClick={() => auth.logout().catch(() => {})}>Log out</button>}</div></header>
    <main><section className="hero"><div><p className="eyebrow"><span className="dot green"/> A WORKING AUTHORIZATION EXAMPLE</p><h1>Private by <em>proof.</em></h1><p className="lede">Your access policy can be more than a convention.<br/>Make it a property your program must preserve.</p></div><div className="hero-side"><span className="big-symbol" aria-hidden="true">⊢</span><p>Lean checks the model.<br/>SQLite stores the rows.<br/>React renders your workspace.</p></div></section>
      <div className="summary-strip"><span><b>{receipt?.theoremCount ?? '—'}</b> audited model theorems</span><span><b>{receipt ? receipt.examples.length - 1 : '—'}</b> rejected candidate changes</span><span>Synthetic data. Real server checks.</span></div>
      <nav className="tabs" aria-label="Demonstration"><button aria-pressed={tab === 'workspace'} onClick={() => setTab('workspace')}>01 &nbsp; Try private notes</button><button aria-pressed={tab === 'agent'} onClick={() => setTab('agent')}>02 &nbsp; Inspect agent changes <span>↗</span></button></nav>
      {tab === 'workspace' ? <div className="demo-grid">{session.user ? <Workspace key={session.epoch} user={session.user}/> : <Account/>}<PolicyCard/></div> : <AgentLab receipt={receipt}/>}
      {receiptError && <p role="alert" className="error">Verification evidence could not be loaded. Reload before relying on the recorded results.</p>}
      <section className="limits"><h2>What this proves. What we still trust.</h2><div><p>The Lean model proves owner/tenant soundness and that hidden rows cannot change its read responses. Authorization evidence is required by the native protected-read API, and decoded rows are checked again before release.</p><p>Authentication facts, the SQLite adapter, compiler, operating system and hosting remain trusted. This is a bounded research demo, not formally verified infrastructure. Native requests use short, serialized transactions; a later request rechecks a revoked session.</p></div><a href="/model.lean" target="_blank" rel="noreferrer">Read the checked model ↗</a><a href="/evidence.json" target="_blank" rel="noreferrer">Download verification evidence ↗</a></section>
    </main><footer><span>LeanApp / Domain first. Execution layers around it.</span><span>MIT · Use disposable credentials · No account recovery</span></footer></>;
}
createRoot(document.getElementById('root')).render(<App/>);
