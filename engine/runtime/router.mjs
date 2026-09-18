import { action } from "./actions.mjs";

/** Same-origin only: a history path is an absolute path (`/…`) without a scheme or authority. */
export function assertPath(path) {
  if (typeof path !== "string" || !path.startsWith("/") || path.startsWith("//"))
    throw new TypeError(`Router navigation requires a same-origin path starting with "/": ${String(path)}`);
  return path;
}

/** `pathname + search` of a browser window, with `pushState`/`replaceState`/`back` and change notification.
 * Listeners run for `popstate` and for pushes/replaces made through this object. */
export function createBrowserHistory(target = globalThis.window) {
  if (!target?.history || !target?.location) throw new TypeError("createBrowserHistory requires a window with history and location");
  const listeners = new Set();
  const current = () => `${target.location.pathname}${target.location.search}`;
  const notify = () => { for (const listener of listeners) listener(current()); };
  let attached = false;
  return Object.freeze({
    current,
    push(path) { target.history.pushState(null, "", assertPath(path)); notify(); },
    replace(path) { target.history.replaceState(null, "", assertPath(path)); notify(); },
    back() { target.history.back(); },
    forward() { target.history.forward(); },
    subscribe(listener) {
      listeners.add(listener);
      if (!attached) { target.addEventListener("popstate", notify); attached = true; }
      return () => {
        listeners.delete(listener);
        if (listeners.size === 0 && attached) { target.removeEventListener("popstate", notify); attached = false; }
      };
    },
  });
}

/** Deterministic history for tests and server rendering. `back`/`forward` notify synchronously. */
export function createMemoryHistory(initial = "/") {
  const entries = [assertPath(initial)];
  let index = 0;
  const listeners = new Set();
  const notify = () => { for (const listener of listeners) listener(entries[index]); };
  return Object.freeze({
    current: () => entries[index],
    push(path) { entries.splice(index + 1); entries.push(assertPath(path)); index++; notify(); },
    replace(path) { entries[index] = assertPath(path); notify(); },
    back() { if (index === 0) return; index--; notify(); },
    forward() { if (index + 1 >= entries.length) return; index++; notify(); },
    subscribe(listener) { listeners.add(listener); return () => listeners.delete(listener); },
    entries: () => [...entries],
    index: () => index,
  });
}

/** The `router` hook primitive: `useLocation(site)` returns `{location, navigate, replace, back}` where
 * `location` is `pathname + search`. The history is created lazily from `window` unless `setHistory` supplied one. */
export function createRouterHooks(React, runtime, { history = null } = {}) {
  let active = history;
  const resolve = () => active ??= createBrowserHistory();
  function useLocation(site = "") {
    if (typeof site !== "string") throw new TypeError("Router site labels must be strings");
    return runtime.primitiveHook("router", site, () => {
      const target = resolve();
      const [location, setLocation] = React.useState(() => target.current());
      React.useEffect(() => target.subscribe(setLocation), [target]);
      return Object.freeze({
        location,
        navigate: path => action(() => { if (assertPath(path) !== target.current()) target.push(path); }),
        replace: path => action(() => { target.replace(path); }),
        back: action(() => { target.back(); }),
      });
    });
  }
  return Object.freeze({ useLocation, setHistory(next) { active = next; }, history: resolve });
}

// URL helpers behind the `LeanReact.Route`/`LeanReact.Query` intrinsics. Hash fragments are dropped.
const withoutHash = location => { const at = location.indexOf("#"); return at < 0 ? location : location.slice(0, at); };
export function splitLocation(location) {
  const value = withoutHash(String(location));
  const at = value.indexOf("?");
  return at < 0 ? [value, ""] : [value.slice(0, at), value.slice(at + 1)];
}
export const segments = path => splitLocation(path)[0].split("/").filter(Boolean).map(part => {
  try { return decodeURIComponent(part); } catch { return part; }
});
export const parseQuery = search => [...new URLSearchParams(String(search).startsWith("?") ? String(search).slice(1) : String(search))];
export const encodeQuery = pairs => new URLSearchParams(pairs).toString();
export const parseNat = segment => /^[0-9]+$/.test(segment) ? BigInt(segment) : null;
