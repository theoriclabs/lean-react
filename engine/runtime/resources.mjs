import { action, isAction, runAction, mapAction } from "./actions.mjs";
import { HookPlacementError } from "./react.mjs";

const idle = Object.freeze({ status: "idle" });
const equalDependencies = (a, b) => a.length === b.length && a.every((value, i) => Object.is(value, b[i]));
const sameScope = (a, b) => a && b && a.key === b.key && a.enabled === b.enabled && equalDependencies(a.dependencies, b.dependencies);
const message = error => {
  try { return error instanceof Error ? String(error.message) : String(error); }
  catch { return "Unknown resource exception"; }
};

/** Async host scheduling only; loaders and all domain parsing remain caller-supplied Actions.
 * Loader results use the explicit host union {ok:true,value} | {ok:false,error}.
 */
export function createResourceHooks(React, runtime, { onCleanupError = error => { throw error; } } = {}) {
  function controller(notify) {
    const owner = { mounted: false, generation: 0n, config: null, current: null, state: idle };
    function publish(state, scope = owner.config) {
      owner.state = state;
      if (owner.mounted) notify({ state, scope });
    }
    function executeCleanup(work) {
      try {
        const result = runAction(work);
        if (result != null && typeof result.then === "function") Promise.resolve(result).catch(onCleanupError);
      } catch (error) { onCleanupError(error); }
    }
    function dispose(request) {
      if (!request || !request.active) return;
      request.active = false;
      request.abort.abort();
      const pending = request.cleanups.splice(0).reverse();
      let firstError;
      for (const cleanup of pending) {
        try { executeCleanup(cleanup); } catch (error) { firstError ??= error; }
      }
      if (firstError) throw firstError;
    }
    function invalidate(scope) {
      const previous = owner.current;
      if (scope && previous?.scope !== scope) return;
      owner.current = null;
      publish(idle);
      dispose(previous);
    }
    function start() {
      const scope = owner.config;
      if (!owner.mounted || !scope?.enabled) return;
      const previousGeneration = owner.generation;
      invalidate();
      // Cleanup can itself request a refresh. Preserve that newer request instead
      // of overwriting its ownership after returning from the cleanup callback.
      if (!owner.mounted || !sameScope(owner.config, scope) || owner.generation !== previousGeneration) return;
      const request = {
        token: Object.freeze({ key: scope.key, generation: ++owner.generation }),
        scope, active: true, settled: false, abort: new AbortController(), cleanups: [],
      };
      owner.current = request;
      publish(Object.freeze({ status: "loading", token: request.token }), scope);
      const eligible = () => owner.mounted && request.active && !request.settled && owner.current === request && sameScope(owner.config, scope);
      const finish = (status, payload) => {
        if (!eligible()) return;
        request.settled = true;
        publish(Object.freeze({ status, token: request.token, ...payload }), scope);
      };
      // The thrown value is retained so an adapter can recognise typed transport failures (CallFailure).
      // Only a failure that will be published reaches the global hook: superseded generations stay silent.
      const reject = error => {
        if (eligible()) runtime.notifyCallFailure?.(error);
        finish("failure", { error: Object.freeze({ kind: "exception", message: message(error), error }) });
      };
      const accept = result => {
        if (!eligible()) return;
        if (!result || (result.ok !== true && result.ok !== false)) {
          reject(new TypeError("Resource loader must return {ok:true,value} or {ok:false,error}; decode the Lean Except in the adapter"));
          return;
        }
        if (result.ok) finish("success", { value: result.value });
        else finish("failure", { error: Object.freeze({ kind: "loader", error: result.error }) });
      };
      const context = Object.freeze({
        token: request.token,
        signal: request.abort.signal,
        cancelled: action(() => !request.active),
        onCleanup: cleanup => action(() => {
          if (!isAction(cleanup)) throw new TypeError("Resource cleanup must be an Action");
          if (request.active) request.cleanups.push(cleanup); else executeCleanup(cleanup);
        }),
      });
      try {
        const result = runAction(scope.load(context));
        if (result != null && typeof result.then === "function") Promise.resolve(result).then(accept).catch(reject);
        else accept(result);
      } catch (error) { reject(error); }
    }
    return Object.assign(owner, {
      publish, invalidate, start,
      refresh: action(start),
      read: action(() => owner.state),
    });
  }

  function useResource(key, load, dependencies = [], enabled = true, site = "") {
    if (typeof key !== "string") throw new TypeError("Resource keys must be explicit strings");
    if (!Array.isArray(dependencies)) throw new TypeError("Resource dependencies must be an array");
    if (typeof enabled !== "boolean") throw new TypeError("Resource enabled must be a host boolean");
    return runtime.primitiveHook("resource", site, () => {
      const [snapshot, setSnapshot] = React.useState({ state: idle, scope: null });
      const ownerRef = React.useRef(null);
      if (ownerRef.current === null) ownerRef.current = controller(setSnapshot);
      const owner = ownerRef.current;
      const dependencyCount = React.useRef(dependencies.length);
      if (dependencyCount.current !== dependencies.length) throw new HookPlacementError("resource dependency count changed");
      const rendered = { key, load, dependencies: [...dependencies], enabled };
      // Invalidate on commit, before passive effects, so an old promise cannot publish
      // under a newly committed key or dependency scope.
      React.useLayoutEffect(() => {
        owner.mounted = true;
        return () => { owner.mounted = false; owner.invalidate(); };
      }, []);
      React.useLayoutEffect(() => {
        if (!sameScope(owner.config, rendered)) {
          owner.config = rendered;
          owner.invalidate();
        } else {
          // A fresh closure does not retrigger loading; refresh uses the latest committed one.
          owner.config.load = load;
        }
      });
      React.useEffect(() => {
        const scope = owner.config;
        if (scope.enabled) owner.start();
        return () => owner.invalidate(scope);
      }, [key, enabled, ...dependencies]);
      return Object.freeze({
        state: enabled && sameScope(snapshot.scope, rendered) ? snapshot.state : idle,
        refresh: owner.refresh,
        read: owner.read,
      });
    });
  }
  return Object.freeze({ useResource });
}

/** Additional semantic intrinsic, with codec obligations documented in INTRINSICS.md.
 * The parent supplies the concrete LeanJS full-arity wrapper; this accepts logical args.
 */
export function createResourceIntrinsic(runtime, resources, abi) {
  for (const method of ["key", "string", "dependencies", "bool", "call", "request", "result", "state", "resource", "unit"]) {
    if (typeof abi?.[method] !== "function") throw new TypeError(`Resource intrinsic requires abi.${method}`);
  }
  return (key, loader, dependencies, enabled, site) => runtime.mapHook(value => abi.resource({
    state: abi.state(value.state),
    refresh: action(() => { runAction(value.refresh); return abi.unit(); }),
    read: mapAction(state => abi.state(state), value.read),
  }), resources.useResource(abi.key(key), request => action(() => {
    const result = runAction(abi.call(loader, [abi.request(request)]));
    return result != null && typeof result.then === "function" ? Promise.resolve(result).then(value => abi.result(value)) : abi.result(result);
  }), abi.dependencies(dependencies), abi.bool(enabled), abi.string(site)));
}
