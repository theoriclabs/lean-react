import { action, isAction, pureAction, runAction, duringRender, isRendering } from "./actions.mjs";
export { action, pureAction, bindAction, mapAction, catchAction, runAction } from "./actions.mjs";

const hookTag = Symbol("LeanReact.Hook");
export const hook = execute => Object.freeze({ [hookTag]: true, execute });
export const pureHook = value => hook(() => value);
export class HookPlacementError extends Error {
  constructor(message) { super(`LeanReact hook placement: ${message}`); this.name = "HookPlacementError"; }
}
const equalSite = (a, b) => a?.kind === b?.kind && a?.site === b?.site;
export function validateHookTrace(expected, actual, name = "component") {
  if (expected.length !== actual.length || expected.some((site, i) => !equalSite(site, actual[i]))) {
    throw new HookPlacementError(`${name} expected ${JSON.stringify(expected)}, received ${JSON.stringify(actual)}. Move conditional hooks into a child component; keep custom hooks unconditional.`);
  }
}

/** Explicit host bridge. React is injected; all props, callbacks and slots are live JS values. */
export function createRuntime(React, { onActionError = error => { throw error; } } = {}) {
  let active = null;
  const ownComponents = new WeakSet();
  const ownContexts = new WeakSet();
  const report = error => onActionError(error);
  function runHook(work) {
    if (!active) throw new HookPlacementError("Hook executed outside a component render");
    if (!work?.[hookTag]) throw new TypeError("Expected a LeanReact Hook");
    return work.execute();
  }
  const bindHook = (first, next) => hook(() => runHook(next(runHook(first))));
  const mapHook = (f, work) => bindHook(work, value => pureHook(f(value)));
  function mark(kind, site = "") {
    if (!active) throw new HookPlacementError(`${kind} called outside a component`);
    const entry = { kind, site: [...active.scope, site].filter(Boolean).join("/") };
    const index = active.trace.length;
    active.trace.push(entry);
    for (const expected of [active.plan, active.previous]) {
      if (expected && !equalSite(expected[index], entry)) validateHookTrace(expected, active.trace, active.name);
    }
  }
  // Host extension point: one trace entry around a fixed sequence of React hooks.
  const primitiveHook = (kind, site, execute) => hook(() => { mark(kind, site); return execute(); });
  const namedHook = (name, work) => hook(() => {
    active.scope.push(name);
    try { return runHook(work); } finally { active.scope.pop(); }
  });
  function component(render, { name = render.name || "Anonymous", hookPlan } = {}) {
    if (isRendering()) throw new Error("LeanReact component created during render; hoist the definition or reuse a stable factory result");
    const plan = hookPlan?.map(entry => ({ kind: entry.kind, site: entry.site ?? "" }));
    function LeanComponent({ leanProps }) {
      const committed = React.useRef(null);
      const frame = { name: LeanComponent.displayName, trace: [], scope: [], previous: committed.current, plan };
      // Always called before user hooks, including renders with zero user hooks.
      React.useLayoutEffect(() => { committed.current = frame.trace; });
      const parent = active;
      active = frame;
      try {
        return duringRender(() => {
          const result = runHook(render(leanProps));
          if (plan) validateHookTrace(plan, frame.trace, frame.name);
          if (frame.previous) validateHookTrace(frame.previous, frame.trace, frame.name);
          return result;
        });
      } finally { active = parent; }
    }
    LeanComponent.displayName = name;
    ownComponents.add(LeanComponent);
    return LeanComponent;
  }
  function nameComponent(name, Component) {
    if (!ownComponents.has(Component)) throw new TypeError("Expected a LeanReact component");
    Component.displayName = name;
    return Component;
  }
  function element(Component, props, key) {
    if (!ownComponents.has(Component)) throw new TypeError("Use foreignElement with an explicit adapter for foreign React components");
    return React.createElement(Component, { leanProps: props, ...(key === undefined ? {} : { key: keyString(key) }) });
  }
  const foreignElement = (Component, props, children = []) => React.createElement(Component, props, ...children);
  const execute = work => {
    try {
      const result = runAction(work);
      if (result != null && typeof result.then === "function") Promise.resolve(result).catch(report);
    } catch (error) { report(error); }
  };
  /** Owns the React ref of an imperative foreign component and its handle lifecycle. Effects run once per
   * mount, so a keyed remount fires `onGone` for the old instance before `onReady` for the new one. */
  function HandleHost({ Component, props, children, lifecycle }) {
    const ref = React.useRef(null);
    const latest = React.useRef(lifecycle);
    latest.current = lifecycle;
    React.useEffect(() => {
      let mounted = true;
      const { onReady, adapt } = latest.current;
      const invoke = (method, args = []) => action(() => {
        if (!mounted) return { ok: false };
        const target = ref.current;
        if (!target || typeof target[method] !== "function") throw new TypeError(`Foreign handle has no method "${method}"`);
        const result = target[method](...args);
        return result != null && typeof result.then === "function" ? result.then(value => ({ ok: true, value })) : { ok: true, value: result };
      });
      execute(onReady(adapt(invoke, action(() => mounted))));
      return () => { mounted = false; execute(latest.current.onGone); };
    }, []);
    return React.createElement(Component, { ...props, ref }, ...children);
  }
  HandleHost.displayName = "LeanReact.HandleHost";
  /** A foreign component exposing an imperative API through `React.useImperativeHandle(ref, ...)`.
   * `adapt(invoke, alive)` builds the handle passed to `onReady(handle)` once per mount, after the first commit:
   * `invoke(method, args)` is an Action resolving to `{ok:true, value}` while mounted and `{ok:false}` after
   * unmount (the stale ref is never touched); `alive` is an Action returning the mount flag. `onGone` is an
   * Action run on unmount. Handle actions are ordinary Actions: they cannot run during render. */
  function handleElement(Component, props, { onReady, onGone = pureAction(undefined), adapt = invoke => invoke }, children = []) {
    if (typeof onReady !== "function") throw new TypeError("handleElement requires onReady(handle) returning an Action");
    return React.createElement(HandleHost, { Component, props, children, lifecycle: { onReady, onGone, adapt } });
  }
  const text = value => {
    if (typeof value !== "string") throw new TypeError("text expects a string");
    return value;
  };
  const fragment = children => React.createElement(React.Fragment, null, ...children);
  function keyString(key) {
    if (typeof key !== "string") throw new TypeError("Keys must be explicit strings; the intrinsic adapter decodes LeanReact.Key");
    return key;
  }
  const keyed = (key, child) => React.createElement(React.Fragment, { key: keyString(key) }, child);
  function keyedEach(items, keyOf, row) {
    const seen = new Set();
    return fragment(items.map(item => {
      const key = keyString(keyOf(item));
      if (seen.has(key)) throw new Error(`LeanReact duplicate sibling key: ${key}`);
      seen.add(key);
      return keyed(key, row(item));
    }));
  }
  const dom = (tag, props = {}, children = []) => React.createElement(tag, props, ...children);
  const modifiers = event => ({ alt: !!event.altKey, ctrl: !!event.ctrlKey, metaKey: !!event.metaKey, shift: !!event.shiftKey });
  // `settle(result, raw, async)` observes the action result; only a synchronous result can still affect `raw`.
  function event(callback, project, settle) {
    return raw => {
      try {
        const payload = Object.freeze(project(raw));
        const result = runAction(callback(payload));
        if (result != null && typeof result.then === "function") {
          Promise.resolve(result).then(value => settle?.(value, raw, true)).catch(report);
        } else settle?.(result, raw, false);
      } catch (error) { report(error); }
    };
  }
  const onPress = work => event(() => work, () => ({}));
  const onClick = callback => event(callback, modifiers);
  const onChange = callback => event(callback, e => ({ value: String(e.currentTarget.value), checked: !!e.currentTarget.checked }));
  const keyPayload = e => ({ key: String(e.key), ...modifiers(e), repeat: !!e.repeat });
  /** The action resolves to the host outcome `"preventDefault"` or `"continue"`; the browser default can only
   * be prevented synchronously, so an asynchronous `"preventDefault"` is reported as an error. */
  const onKeyDown = callback => event(callback, keyPayload, (outcome, raw, async) => {
    if (outcome !== "preventDefault") return;
    if (async) throw new Error("LeanReact KeyOutcome.preventDefault resolved asynchronously; decide it before awaiting host work");
    raw.preventDefault();
  });
  const onKeyUp = callback => event(callback, keyPayload);
  const focusPayload = e => ({ value: e.currentTarget?.value == null ? "" : String(e.currentTarget.value) });
  const onFocus = callback => event(callback, focusPayload);
  const onBlur = callback => event(callback, focusPayload);
  const onInput = callback => event(callback, e => ({ value: String(e.currentTarget.value ?? ""), isComposing: !!e.nativeEvent?.isComposing }));
  // Clipboard data is only readable during dispatch, so it is copied before any deferred work.
  const onPaste = callback => event(callback, e => {
    const data = e.clipboardData;
    const html = data?.getData("text/html") ?? "";
    return { text: data?.getData("text/plain") ?? "", html: html === "" ? null : html };
  });
  const onMouseEnter = callback => event(callback, modifiers);
  const onMouseLeave = callback => event(callback, modifiers);
  const onScroll = callback => event(callback, e => ({
    scrollTop: Math.floor(Number(e.currentTarget.scrollTop) || 0), scrollLeft: Math.floor(Number(e.currentTarget.scrollLeft) || 0),
  }));
  /** A form submit never navigates: the default is prevented before the action runs. */
  const onSubmit = work => raw => { raw.preventDefault(); event(() => work, () => ({}))(raw); };
  function useState(initial, site = "") {
    return hook(() => {
      mark("state", site);
      const [value, setValue] = React.useState(() => initial);
      const latest = React.useRef(value);
      React.useLayoutEffect(() => { latest.current = value; });
      return Object.freeze({
        value,
        set: next => action(() => { setValue(() => next); }),
        // React applies every updater to the latest queued state. Updaters must be pure.
        modify: update => action(() => { setValue(previous => duringRender(() => update(previous))); }),
        read: action(() => latest.current),
      });
    });
  }
  function createContext(name, defaultValue) {
    if (isRendering()) throw new Error("LeanReact context created during render; hoist it to a stable declaration");
    const reactContext = React.createContext(defaultValue);
    reactContext.displayName = name;
    const context = Object.freeze({ name, reactContext });
    ownContexts.add(context);
    provider(context);
    return context;
  }
  function assertContext(context) {
    if (!ownContexts.has(context)) throw new TypeError("Expected a context created by this LeanReact runtime");
  }
  function provide(context, value, child) {
    assertContext(context);
    return React.createElement(context.reactContext.Provider, { value }, child);
  }
  const providerCache = new WeakMap();
  function provider(context) {
    assertContext(context);
    if (!providerCache.has(context)) providerCache.set(context, component(props => pureHook(provide(context, props.value, props.children)), { name: `${context.name}.Provider` }));
    return providerCache.get(context);
  }
  function useContext(context, site = "") {
    return hook(() => { mark("context", site); assertContext(context); return React.useContext(context.reactContext); });
  }
  function useEffect(dependencies, setup, site = "") {
    if (!Array.isArray(dependencies)) throw new TypeError("useEffect requires an explicit, fixed-length dependency array");
    return hook(() => {
      mark("effect", site);
      const previousLength = React.useRef(dependencies.length);
      if (previousLength.current !== dependencies.length) throw new HookPlacementError("effect dependency count changed");
      React.useEffect(() => {
        let disposed = false;
        let cleanup = null;
        const acceptCleanup = result => {
          if (!isAction(result)) throw new TypeError("Managed effect setup must return a cleanup Action (pureAction(undefined) for none)");
          if (disposed) executeCleanup(result); else cleanup = result;
        };
        const executeCleanup = work => {
          try {
            const result = runAction(work);
            if (result != null && typeof result.then === "function") Promise.resolve(result).catch(report);
          } catch (error) { report(error); }
        };
        try {
          const result = runAction(setup);
          if (result != null && typeof result.then === "function") Promise.resolve(result).then(acceptCleanup).catch(report);
          else acceptCleanup(result);
        } catch (error) { report(error); }
        return () => {
          disposed = true;
          const work = cleanup;
          cleanup = null;
          if (work) executeCleanup(work);
        };
      }, dependencies);
      return undefined;
    });
  }
  return Object.freeze({ component, nameComponent, element, foreignElement, handleElement, text, fragment, empty: null, keyed, keyedEach,
    dom, event, onPress, onClick, onChange, onKeyDown, onKeyUp, onFocus, onBlur, onInput, onPaste, onMouseEnter, onMouseLeave,
    onScroll, onSubmit, useState, createContext, provide, provider, useContext, useEffect,
    runHook, bindHook, mapHook, namedHook, primitiveHook });
}
