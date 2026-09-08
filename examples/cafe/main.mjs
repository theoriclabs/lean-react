import React, { useEffect, useMemo, useRef, useState, useSyncExternalStore } from 'react';
import { createRoot } from 'react-dom/client';
import { createAuthClient } from '../../engine/LeanApp/AuthClient.mjs';
import { preview } from './domain.mjs';
import { createCafeClient, errorMessage, formatMoney, INITIAL_CONFIGURATION, parsePreview } from './client.mjs';

const auth = createAuthClient();
const recipes = createCafeClient({ auth });
const label = value => value.charAt(0).toUpperCase() + value.slice(1);
const describe = c => `${label(c.temperature)} · ${label(c.size)} · ${label(c.milk)} milk · ${label(c.shots)} shot${c.shots === 'single' ? '' : 's'}${c.decaf ? ' · Decaf' : ''}`;
const routeFromHash = () => ['saved', 'why'].includes(window.location.hash.slice(1)) ? window.location.hash.slice(1) : 'configure';
const ruleMessages = {
  small_iced: 'A small cup leaves no room for ice. Choose regular or large, or enjoy it hot.',
  decaf_triple: 'Triple shots are not available with decaf. Choose single or double, or turn decaf off.',
  invalid_configuration: 'This combination could not be checked. Please review your choices.',
  negative_price: 'A price is not available for this combination. Please try another cup.',
  unavailable: 'The preview is unavailable right now. Please try again later.',
};

function Cup({ configuration, small = false }) {
  return <div className={`cup-scene ${configuration.temperature} size-${configuration.size}${small ? ' mini' : ''}`} aria-hidden="true">
    <div className="cup-halo" />
    <div className="cup-steam"><i /><i /><i /></div>
    <div className="cup-shadow" />
    <div className="cup-saucer" />
    <div className="cup-handle" />
    <div className="cup-body"><span className="cup-mark">p<span>&amp;</span>p</span><span className="cup-rule" /></div>
    <div className="cup-rim"><div className="coffee"><span className="latte-art" /><i className="ice ice-one" /><i className="ice ice-two" /><i className="ice ice-three" /></div></div>
  </div>;
}

function checkedPreview(configuration) {
  try { return parsePreview(preview(configuration)); }
  catch { return { ok: false, error: 'unavailable' }; }
}

function unavailableReason(configuration) {
  const result = checkedPreview(configuration);
  return result.ok ? '' : ruleMessages[result.error] ?? ruleMessages.unavailable;
}

function Choice({ number, title, name, values, configuration, onChange }) {
  const options = values.map(value => ({ value, reason: unavailableReason({ ...configuration, [name]: value }) }));
  const reasons = [...new Set(options.map(option => option.reason).filter(Boolean))];
  return <fieldset className={`choice choice-${name}`}>
    <legend><span className="step-number">{number}</span>{title}</legend>
    <div className="choices">{options.map(({ value, reason }) => <label className="choice-option" key={value} title={reason || undefined}>
      <input type="radio" name={name} value={value} checked={configuration[name] === value}
        disabled={Boolean(reason)} aria-describedby={reason ? `${name}-availability` : undefined} onChange={() => onChange(value)} />
      <span>{label(value)}</span>
    </label>)}</div>
    {reasons.length > 0 && <p className="hint availability-hint" id={`${name}-availability`}>{reasons.join(' ')}</p>}
  </fieldset>;
}

function Modal({ children, onClose, labelledBy, className = '' }) {
  const ref = useRef(null);
  useEffect(() => {
    const dialog = ref.current;
    dialog.showModal();
    return () => { if (dialog.open) dialog.close(); };
  }, []);
  return <dialog ref={ref} className={`modal ${className}`} aria-labelledby={labelledBy}
    onCancel={event => { event.preventDefault(); onClose(); }}>
    {children}
  </dialog>;
}

function AccountDialog({ initialMode, onClose, onSuccess }) {
  const session = useSyncExternalStore(auth.subscribe, auth.getSnapshot);
  const [mode, setMode] = useState(initialMode);
  const [error, setError] = useState('');
  const form = useRef(null);
  function close() { form.current?.reset(); onClose(); }
  async function submit(event) {
    event.preventDefault();
    const username = form.current.elements.username.value;
    let password = form.current.elements.password.value;
    form.current.elements.password.value = '';
    setError('');
    const pending = auth[mode](username, password);
    password = '';
    const owner = auth.getSnapshot().epoch;
    try {
      await pending;
      if (auth.getSnapshot().epoch === owner) onSuccess(mode === 'signup' ? 'Your account is ready. Your cup is just as you left it.' : 'Welcome back. Your cup is just as you left it.');
    } catch (cause) {
      if (auth.getSnapshot().epoch === owner && cause.code !== 'auth.stale') {
        setError(errorMessage(cause));
        form.current?.elements.password.focus();
      }
    }
  }
  return <Modal labelledBy="account-title" onClose={close}>
    <button type="button" className="close-button" aria-label="Close account form" onClick={close}>×</button>
    <p className="eyebrow">A place for your favorites</p>
    <h2 id="account-title">{mode === 'signup' ? 'Keep your daily ritual.' : 'Your usual awaits.'}</h2>
    <p className="muted">{mode === 'signup' ? 'Create an account to save your own collection. Your current cup will stay right here.' : 'Log in to return to your saved recipes.'}</p>
    <div className="account-modes" aria-label="Account action">{['signup', 'login'].map(value =>
      <button key={value} type="button" aria-pressed={mode === value} disabled={session.transitioning}
        onClick={() => { form.current?.reset(); setError(''); setMode(value); }}>{value === 'signup' ? 'Sign up' : 'Log in'}</button>)}</div>
    <form ref={form} onSubmit={submit} noValidate aria-busy={session.transitioning}>
      <label className="input-label" htmlFor="username">Username</label>
      <input id="username" name="username" autoComplete="username" autoCapitalize="none" spellCheck={false} required
        aria-describedby="username-help" disabled={session.transitioning} autoFocus />
      <p id="username-help" className="hint">3–32 letters, numbers, underscores, or hyphens.</p>
      <label className="input-label" htmlFor="password">Password</label>
      <input id="password" name="password" type="password" autoComplete={mode === 'signup' ? 'new-password' : 'current-password'}
        required aria-describedby={error ? 'password-help account-error' : 'password-help'} aria-invalid={Boolean(error)} disabled={session.transitioning} />
      <p id="password-help" className="hint">{mode === 'signup' ? '15–128 characters, including spaces. Maximum 1024 UTF-8 bytes.' : 'Use the password you chose when you signed up.'}</p>
      {error && <p id="account-error" className="error-message" role="alert">{error}</p>}
      <button className="button primary full-width" type="submit" disabled={session.transitioning}>
        {session.transitioning ? 'One moment…' : mode === 'signup' ? 'Create account' : 'Log in'}<span aria-hidden="true">↗</span>
      </button>
    </form>
    <p className="account-footnote">A demo collection. No orders. No payments.</p>
  </Modal>;
}

function WhyLean() {
  const points = [
    ['One recipe for the rules', 'The same pricing and admissibility model runs in the browser and the native backend. Your preview and saved recipe use one set of rules.'],
    ['Clear answers for unusual cups', 'The Lean model disables unavailable choices and explains why. Change your cup and the available options update with it.'],
    ['Every cent accounted for', 'The model uses exact, currency-tagged money. Prices are displayed from integer cents without floating-point rounding.'],
    ['Checked again when you save', 'The backend reconstructs and checks all user input. A browser preview never substitutes for the server’s checks.'],
    ['Small pieces, clear jobs', 'SQLite, HTTP, and React are adapters around the model: storage, transport, and the interface you see here.'],
  ];
  return <section className="why-page" aria-labelledby="why-title">
    <p className="eyebrow">Behind the counter</p>
    <h1 id="why-title">A thoughtful cup.<br /><em>A shared set of rules.</em></h1>
    <p className="page-intro">Proof &amp; Pour is a small demonstration of what Lean can bring to an everyday app.</p>
    <div className="why-list">{points.map(([title, body], index) => <article key={title}>
      <span className="step-number">0{index + 1}</span><div><h2>{title}</h2><p>{body}</p></div>
    </article>)}</div>
    <p className="why-note">This is an experimental demo, not an end-to-end formally verified or production-ready service. It does not take payments or place real orders.</p>
    <a className="button primary" href="#configure">Back to your cup <span aria-hidden="true">↗</span></a>
  </section>;
}

function App() {
  const session = useSyncExternalStore(auth.subscribe, auth.getSnapshot);
  const collection = useSyncExternalStore(recipes.subscribe, recipes.getSnapshot);
  const [route, setRoute] = useState(routeFromHash);
  const [configuration, setConfiguration] = useState({ ...INITIAL_CONFIGURATION });
  const [name, setName] = useState('');
  const [accountMode, setAccountMode] = useState(null);
  const [notice, setNotice] = useState('');
  const [authError, setAuthError] = useState('');
  const [deleting, setDeleting] = useState(null);
  const main = useRef(null);
  const result = useMemo(() => checkedPreview(configuration), [configuration]);
  const decafReason = unavailableReason({ ...configuration, decaf: !configuration.decaf });

  useEffect(() => {
    auth.restore().catch(error => {
      if (error.code !== 'auth.required' && error.code !== 'auth.stale') setAuthError(errorMessage(error));
    });
    const navigate = () => { setRoute(routeFromHash()); requestAnimationFrame(() => main.current?.focus()); };
    window.addEventListener('hashchange', navigate);
    return () => window.removeEventListener('hashchange', navigate);
  }, []);
  useEffect(() => {
    setDeleting(null);
    if (session.user && !session.transitioning) recipes.load().catch(() => {});
  }, [session.epoch, session.user, session.transitioning]);

  function openAccount(mode) { setAuthError(''); setNotice(''); setAccountMode(mode); }
  function change(key, value) {
    setConfiguration(current => ({ ...current, [key]: value }));
    setNotice(''); recipes.dismissMessage();
  }
  async function logout() {
    setNotice(''); setAuthError(''); setDeleting(null);
    const pending = auth.logout();
    const owner = auth.getSnapshot().epoch;
    try { await pending; if (auth.getSnapshot().epoch === owner) setNotice('You are logged out. Your current cup is still here.'); }
    catch (error) { if (auth.getSnapshot().epoch === owner && error.code !== 'auth.stale') setAuthError(errorMessage(error)); }
  }
  async function save(event) {
    event.preventDefault(); setNotice('');
    if (!session.user) { openAccount('signup'); return; }
    try { await recipes.save(name, configuration); } catch { /* The client publishes a safe, session-owned error. */ }
  }
  function useRecipe(recipe) {
    setConfiguration({ ...recipe.configuration }); setName(recipe.name);
    setNotice('Recipe loaded. Make it yours, then save a new recipe.'); recipes.dismissMessage();
    window.location.hash = 'configure';
  }
  const deletion = deleting?.epoch === session.epoch && session.user ? deleting.recipe : null;
  const collectionError = collection.error ? errorMessage(collection.error) : '';

  return <>
    <a className="skip-link" href="#main-content">Skip to content</a>
    <header className="site-header">
      <a href="#configure" className="brand" aria-label="Proof & Pour home"><span className="brand-cup" aria-hidden="true" /><span>Proof <i>&amp;</i> Pour<span className="brand-subtitle">YOUR DAILY CUP, CONSIDERED.</span></span></a>
      <nav aria-label="Main navigation">
        <a href="#configure" aria-current={route === 'configure' ? 'page' : undefined}>Make a cup</a>
        <a href="#saved" aria-current={route === 'saved' ? 'page' : undefined}>Saved recipes{session.user && collection.recipes.length > 0 && <span className="recipe-count">{collection.recipes.length}</span>}</a>
        <a href="#why" aria-current={route === 'why' ? 'page' : undefined}>Why Lean</a>
      </nav>
      <div className="account-nav"><span className="demo-badge">DEMO</span>{session.user
        ? <><span className="username" title={session.user.username}>{session.user.username}</span><button className="text-button" onClick={logout}>Log out</button></>
        : <button className="text-button" disabled={session.transitioning} onClick={() => openAccount('login')}>{session.transitioning ? 'Connecting…' : 'Log in'}<span aria-hidden="true">↗</span></button>}</div>
    </header>

    <main id="main-content" tabIndex={-1} ref={main}>
      <div className="global-notice" role="status" aria-live="polite">{notice || collection.notice}</div>
      {authError && <p className="error-message global-error" role="alert">{authError}</p>}
      {route === 'configure' && <>
        <section className="page-heading" aria-labelledby="configure-title">
          <div><p className="eyebrow"><span className="status-dot" /> GOOD THINGS, MADE YOUR WAY</p><h1 id="configure-title">A little ritual,<br /><em>exactly yours.</em></h1></div>
          <p className="page-intro">Hot or iced. A little oat. An extra shot.<br />Find your favorite cup, then keep it close.</p>
        </section>
        <div className="configurator">
          <section className="preview-card" aria-label="Your cup preview">
            <div className="preview-art"><div className="art-caption"><span>THE DAILY POUR</span><span>01 / YOUR CREATION</span></div>
              <Cup configuration={configuration} /><span className="art-note">a moment, made for you.</span>
            </div>
            <div className="cup-details"><div><p className="eyebrow">YOUR CUP</p><h2>{configuration.decaf ? 'Decaf' : label(configuration.temperature)} {configuration.milk} latte</h2><p className="cup-description">{describe(configuration)}</p></div>
              <div className="price" aria-live="polite" aria-atomic="true"><span>{result.ok ? formatMoney(result.priceMinor) : '—'}</span><small>{result.ok ? 'USD · demo price' : 'Unavailable'}</small></div>
            </div>
            <p className="preview-footnote"><span aria-hidden="true">✳</span> A free preview. No account needed.</p>
          </section>
          <section className="configuration-card" aria-labelledby="configuration-title">
            <div className="section-heading"><h2 id="configuration-title">Make yourself a cup.</h2><span>YOUR KIND OF COFFEE</span></div>
            <Choice number="01" title="Temperature" name="temperature" values={['hot', 'iced']} configuration={configuration} onChange={value => change('temperature', value)} />
            <Choice number="02" title="Size" name="size" values={['small', 'regular', 'large']} configuration={configuration} onChange={value => change('size', value)} />
            <Choice number="03" title="Milk" name="milk" values={['whole', 'skim', 'oat', 'almond', 'soy']} configuration={configuration} onChange={value => change('milk', value)} />
            <Choice number="04" title="Espresso shots" name="shots" values={['single', 'double', 'triple']} configuration={configuration} onChange={value => change('shots', value)} />
            <label className="decaf-option" title={decafReason || undefined}><span><strong>All the ritual. A little less buzz.</strong><span>Make it decaf</span></span>
              <input type="checkbox" name="decaf" checked={configuration.decaf} disabled={Boolean(decafReason)}
                aria-describedby={decafReason ? 'decaf-availability' : undefined} onChange={event => change('decaf', event.target.checked)} /><span className="switch-track" aria-hidden="true" />
            </label>
            {decafReason && <p className="hint availability-hint" id="decaf-availability">{decafReason}</p>}
            {!result.ok && <p className="error-message rule-message" role="alert">{ruleMessages[result.error]}</p>}
            <form className="save-form" onSubmit={save} noValidate>
              <label className="input-label" htmlFor="recipe-name">Give your favorite a name</label>
              <input id="recipe-name" name="recipe-name" value={name} onChange={event => { setName(event.target.value); recipes.dismissMessage(); }}
                placeholder="e.g. My slow Sunday" required aria-describedby="recipe-name-help" />
              <p className="hint" id="recipe-name-help">1–60 characters. Save up to 40 recipes in your collection.</p>
              {collectionError && <p className="error-message" role="alert">{collectionError}</p>}
              <button className="button primary full-width" type="submit" disabled={!result.ok || session.transitioning || Boolean(collection.busy)}>
                {collection.busy === 'save' ? 'Saving your cup…' : session.user ? 'Save recipe' : 'Sign up to save'}<span aria-hidden="true">↗</span>
              </button>
              <p className="save-hint">{session.user ? 'Saved to your personal recipe collection.' : <>Already have an account? <button type="button" className="inline-button" onClick={() => openAccount('login')}>Log in</button></>}</p>
            </form>
          </section>
        </div>
      </>}

      {route === 'saved' && <section className="saved-page" aria-labelledby="saved-title">
        <div className="page-heading"><div><p className="eyebrow">THE ONES YOU COME BACK TO</p><h1 id="saved-title">Your usuals.</h1></div>
          <p className="page-intro">A little collection of very good cups.<br />Up to 40 recipes, just for you.</p></div>
        {session.user ? <>
          <div className="collection-toolbar"><p>{collection.recipes.length} saved {collection.recipes.length === 1 ? 'recipe' : 'recipes'}</p>
            <button className="text-button" disabled={Boolean(collection.busy)} onClick={() => recipes.load().catch(() => {})}>{collection.busy === 'list' ? 'Refreshing…' : 'Refresh collection'}<span aria-hidden="true">↻</span></button></div>
          {collectionError && !deletion && <p className="error-message" role="alert">{collectionError}</p>}
          {collection.busy === 'list' && !collection.loaded && <p className="loading-message" role="status">Finding your favorites…</p>}
          {!collection.loaded && !collection.busy && !collection.error && <p className="loading-message">Refresh to see your complete collection.</p>}
          {collection.loaded && collection.recipes.length === 0 && <div className="empty-state"><span className="empty-mark" aria-hidden="true">✳</span><h2>Your first favorite is waiting.</h2><p>Find your perfect combination and save it here.<br />Tomorrow’s you will know just what to make.</p><a className="button primary" href="#configure">Make your first cup <span aria-hidden="true">↗</span></a></div>}
          <div className="recipe-grid">{collection.recipes.map(recipe => <article className="recipe-card" key={recipe.id}>
            <div className="recipe-art"><Cup configuration={recipe.configuration} small /><span className="recipe-temperature">{recipe.configuration.decaf ? 'DECAF · ' : ''}{recipe.configuration.temperature.toUpperCase()}</span></div>
            <div className="recipe-body"><div className="recipe-title"><h2>{recipe.name}</h2><span>{formatMoney(recipe.priceMinor)}</span></div><p className="hint price-source">USD · saved price</p><p className="recipe-description">{describe(recipe.configuration)}</p>
              <div className="recipe-actions"><button className="text-button" onClick={() => useRecipe(recipe)}>Make this again <span aria-hidden="true">↗</span></button><button className="delete-button" disabled={Boolean(collection.busy)} aria-label={`Delete ${recipe.name}`} onClick={() => { recipes.dismissMessage(); setDeleting({ recipe, epoch: session.epoch }); }}>Delete</button></div>
            </div>
          </article>)}</div>
        </> : <div className="empty-state"><span className="empty-mark" aria-hidden="true">✳</span><h2>{session.transitioning ? 'Opening your collection…' : 'Good cups deserve keeping.'}</h2><p>Log in to see your favorites, or create an account<br />and start your own collection.</p><div className="empty-actions"><button className="button primary" disabled={session.transitioning} onClick={() => openAccount('signup')}>Create account <span aria-hidden="true">↗</span></button><button className="button secondary" disabled={session.transitioning} onClick={() => openAccount('login')}>Log in</button></div><a className="inline-link" href="#configure">You can always preview a cup for free.</a></div>}
      </section>}

      {route === 'why' && <WhyLean />}
    </main>
    <footer className="site-footer"><span>Proof <i>&amp;</i> Pour <span className="footer-dot">·</span> A small ritual, thoughtfully made.</span><span>Demo only. No real orders or payments. <a href="#why">Made with Lean ↗</a></span></footer>
    {accountMode && <AccountDialog initialMode={accountMode} onClose={() => setAccountMode(null)} onSuccess={message => { setAccountMode(null); setAuthError(''); setNotice(message); }} />}
    {deletion && <Modal labelledBy="delete-title" onClose={() => setDeleting(null)}>
      <p className="eyebrow">Your collection</p><h2 id="delete-title">Let this one go?</h2><p>Delete <strong className="recipe-delete-name">{deletion.name}</strong> from your saved recipes? This cannot be undone.</p>
      {collection.error?.action === 'delete' && <p className="error-message" role="alert">{collectionError}</p>}
      <div className="dialog-actions"><button className="button secondary" autoFocus onClick={() => setDeleting(null)}>Keep recipe</button><button className="button danger" disabled={Boolean(collection.busy)} onClick={async () => {
        const owner = session.epoch;
        try { await recipes.delete(deletion.id); if (auth.getSnapshot().epoch === owner) setDeleting(null); } catch { /* Display the client’s sanitized error. */ }
      }}>{collection.busy === 'delete' ? 'Deleting…' : 'Delete recipe'}</button></div>
    </Modal>}
  </>;
}

createRoot(document.getElementById('root')).render(<App />);
