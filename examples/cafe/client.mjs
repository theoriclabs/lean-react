/** Wire parsing and session-owned recipe state. Pricing and admissibility live in Lean. */
export const INITIAL_CONFIGURATION = Object.freeze({
  temperature: 'hot', size: 'regular', milk: 'whole', shots: 'double', decaf: false,
});

const fields = {
  temperature: ['hot', 'iced'], size: ['small', 'regular', 'large'],
  milk: ['whole', 'skim', 'oat', 'almond', 'soy'], shots: ['single', 'double', 'triple'],
};
const object = value => value !== null && typeof value === 'object' && !Array.isArray(value);
const exact = (value, keys) => object(value) && Object.keys(value).length === keys.length &&
  keys.every(key => Object.hasOwn(value, key));
const decimal = value => typeof value === 'string' && /^(0|[1-9][0-9]*)$/.test(value);

export class CafeError extends Error {
  constructor(code) { super(code); this.name = 'CafeError'; this.code = code; }
}
const fail = code => { throw new CafeError(code); };

export function parseConfiguration(value) {
  if (!exact(value, [...Object.keys(fields), 'decaf']) || typeof value.decaf !== 'boolean' ||
      !Object.entries(fields).every(([key, choices]) => choices.includes(value[key]))) fail('cafe.protocol');
  return Object.freeze(Object.fromEntries([...Object.keys(fields), 'decaf'].map(key => [key, value[key]])));
}

export function parseRecipe(value) {
  if (!exact(value, ['id', 'name', 'configuration', 'priceMinor']) ||
      typeof value.id !== 'string' || !value.id || typeof value.name !== 'string' ||
      !decimal(value.priceMinor)) fail('cafe.protocol');
  return Object.freeze({ id: value.id, name: value.name,
    configuration: parseConfiguration(value.configuration), priceMinor: value.priceMinor });
}

export function parseRecipes(value) {
  if (!Array.isArray(value)) fail('cafe.protocol');
  const recipes = value.map(parseRecipe);
  if (new Set(recipes.map(recipe => recipe.id)).size !== recipes.length) fail('cafe.protocol');
  return Object.freeze(recipes);
}

export function formatMoney(priceMinor) {
  if (!decimal(priceMinor)) fail('cafe.protocol');
  const cents = BigInt(priceMinor);
  return `$${(cents / 100n).toLocaleString('en-US')}.${String(cents % 100n).padStart(2, '0')}`;
}

const previewErrors = new Set(['small_iced', 'decaf_triple', 'invalid_configuration', 'negative_price']);
export function parsePreview(value) {
  if (exact(value, ['ok', 'priceMinor']) && value.ok === true && decimal(value.priceMinor))
    return Object.freeze({ ok: true, priceMinor: value.priceMinor });
  if (exact(value, ['ok', 'error']) && value.ok === false && previewErrors.has(value.error))
    return Object.freeze({ ok: false, error: value.error });
  fail('cafe.protocol');
}

const messages = Object.freeze({
  'auth.invalid_credentials': 'That username and password do not match. Please try again.',
  'auth.username_unavailable': 'That username is taken. Please choose another.',
  'auth.invalid_username': 'Use 3–32 letters, numbers, underscores, or hyphens for your username.',
  'auth.invalid_password': 'Use a password with 15–128 characters and at most 1024 UTF-8 bytes.',
  'auth.required': 'Please log in to save or see your recipes.',
  'auth.forbidden': 'We could not authorize that request. Please log in again.',
  'auth.throttled': 'Too many attempts. Give it a moment before trying again.',
  'auth.unavailable': 'We could not reach the café. Please try again when your connection is ready.',
  'auth.protocol': 'We could not read the service response. Please try again later.',
  'cafe.protocol': 'We could not read the recipe response. Please refresh your collection before trying again.',
  'cafe.busy': 'Please wait for your current request to finish.',
});
export const errorMessage = error => Object.hasOwn(messages, error?.code) ? messages[error.code] :
  'We could not complete that request. Check your details and try again.';
const safeError = error => new CafeError(Object.hasOwn(messages, error?.code) ||
  error?.code === 'auth.stale' ? error.code : 'cafe.failed');

export function createCafeClient({ auth }) {
  let session = auth.getSnapshot(), serial = 0, disposed = false;
  const listeners = new Set();
  const empty = () => ({ recipes: Object.freeze([]), loaded: false, busy: null, error: null, notice: '' });
  let state = Object.freeze({ ...empty(), epoch: session.epoch });
  const publish = next => {
    if (disposed) return;
    state = Object.freeze(next);
    for (const listener of listeners) listener();
  };
  const unsubscribe = auth.subscribe(() => {
    const next = auth.getSnapshot();
    if (next.epoch !== session.epoch || next.user !== session.user || next.transitioning !== session.transitioning) {
      ++serial;
      publish({ ...empty(), epoch: next.epoch });
    }
    session = next;
  });

  async function run(name, kind, input, parse, update) {
    const owner = auth.getSnapshot();
    if (disposed || owner.transitioning || !owner.user) fail('auth.required');
    if (state.busy) fail('cafe.busy');
    const ticket = ++serial;
    const current = () => !disposed && ticket === serial && auth.getSnapshot().epoch === owner.epoch &&
      auth.getSnapshot().user === owner.user && !auth.getSnapshot().transitioning;
    publish({ ...state, busy: name, error: null, notice: '' });
    try {
      const raw = await auth.call(`/api/recipes/${name}`, {
        operation: { namespace: 'cafe', name, version: '1' }, kind, input,
      });
      if (!current()) fail('auth.stale');
      const value = parse(raw);
      const next = update(value);
      publish({ ...state, ...next, busy: null });
      return value;
    } catch (error) {
      if (!current()) throw new CafeError('auth.stale');
      const safe = safeError(error);
      publish({ ...state, busy: null, error: Object.freeze({ code: safe.code, action: name }) });
      throw safe;
    }
  }

  return Object.freeze({
    getSnapshot: () => state,
    subscribe(listener) { listeners.add(listener); return () => listeners.delete(listener); },
    load: () => run('list', 'query', null, parseRecipes, recipes => ({ recipes, loaded: true })),
    save(name, configuration) {
      if (typeof name !== 'string') return Promise.reject(new CafeError('cafe.protocol'));
      let draft;
      try { draft = parseConfiguration(configuration); } catch (error) { return Promise.reject(error); }
      return run('save', 'command', { name: name.trim(), configuration: draft }, parseRecipe, recipe => {
        if (state.recipes.some(existing => existing.id === recipe.id)) fail('cafe.protocol');
        return { recipes: Object.freeze([...state.recipes, recipe]), notice: 'Recipe saved to your collection.' };
      });
    },
    delete(id) {
      if (typeof id !== 'string' || !id) return Promise.reject(new CafeError('cafe.protocol'));
      return run('delete', 'command', id, value => {
        if (value !== null) fail('cafe.protocol');
        return null;
      }, () => ({ recipes: Object.freeze(state.recipes.filter(recipe => recipe.id !== id)), notice: 'Recipe deleted.' }));
    },
    dismissMessage() { publish({ ...state, error: null, notice: '' }); },
    dispose() { disposed = true; ++serial; unsubscribe(); listeners.clear(); },
  });
}
