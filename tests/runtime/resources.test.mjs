import test from "node:test";
import assert from "node:assert/strict";
import { JSDOM } from "jsdom";
import { createRuntime, hook, action, runAction, HookPlacementError } from "../../engine/runtime/react.mjs";
import { createResourceHooks, createResourceIntrinsic } from "../../engine/runtime/resources.mjs";

const window = new JSDOM("<!doctype html><html><body></body></html>").window;
globalThis.window = window;
globalThis.document = window.document;
globalThis.IS_REACT_ACT_ENVIRONMENT = true;
const React = await import("react");
const { createRoot } = await import("react-dom/client");
const { act } = React;
const runtime = createRuntime(React);
const resources = createResourceHooks(React, runtime);

function deferred() {
  let resolve, reject;
  const promise = new Promise((ok, error) => { resolve = ok; reject = error; });
  return { promise, resolve, reject };
}
function pendingLoader() {
  const calls = [];
  const load = request => action(() => {
    const pending = deferred();
    calls.push({ request, ...pending });
    return pending.promise;
  });
  return { calls, load };
}
async function mount(props, { strict = false, extension = resources } = {}) {
  const renders = [];
  let current;
  const Component = runtime.component(input => hook(() => {
    current = runtime.runHook(extension.useResource(input.key, input.load, input.dependencies ?? [], input.enabled ?? true, "request"));
    renders.push(current.state);
    return runtime.dom("output", {}, [runtime.text(String(current.state.status ?? "encoded"))]);
  }), { name: "ResourceConsumer", hookPlan: [{ kind: "resource", site: "request" }] });
  const container = document.createElement("div");
  document.body.append(container);
  const root = createRoot(container);
  const tree = input => strict ? React.createElement(React.StrictMode, null, runtime.element(Component, input)) : runtime.element(Component, input);
  await act(() => root.render(tree(props)));
  return {
    renders, container, get current() { return current; },
    render: async input => { await act(() => root.render(tree(input))); },
    refresh: async () => { await act(() => runAction(current.refresh)); },
    close: async () => { await act(() => root.unmount()); container.remove(); },
  };
}
async function settle(call, value) { await act(async () => { call.resolve(value); await call.promise; }); }

test("resources start after render and suppress deliberately reordered refresh results", async () => {
  const loader = pendingLoader();
  const constructed = resources.useResource("tickets", loader.load);
  assert.ok(constructed);
  assert.equal(loader.calls.length, 0);
  const f = await mount({ key: "tickets", load: loader.load });
  try {
    assert.equal(f.renders[0].status, "idle");
    assert.equal(f.current.state.status, "loading");
    assert.equal(loader.calls.length, 1);
    assert.deepEqual(loader.calls[0].request.token, { key: "tickets", generation: 1n });
    await f.refresh();
    assert.equal(loader.calls.length, 2);
    assert.equal(loader.calls[0].request.signal.aborted, true);
    assert.equal(runAction(loader.calls[0].request.cancelled), true);
    await settle(loader.calls[1], { ok: true, value: { result: "new" } });
    await settle(loader.calls[0], { ok: true, value: { result: "old" } });
    assert.deepEqual(f.current.state, { status: "success", token: { key: "tickets", generation: 2n }, value: { result: "new" } });
    assert.deepEqual(runAction(f.current.read), f.current.state);
  } finally { await f.close(); }
});

test("key changes invalidate old requests and cleanup, including callbacks retained before the change", async () => {
  const calls = [], cleanups = [];
  const load = request => action(() => {
    const pending = deferred();
    calls.push({ request, ...pending });
    runAction(request.onCleanup(action(() => cleanups.push(request.token))));
    return pending.promise;
  });
  const f = await mount({ key: "a", load });
  const oldRefresh = f.current.refresh;
  try {
    await f.render({ key: "b", load });
    assert.equal(calls.length, 2);
    assert.deepEqual(cleanups, [{ key: "a", generation: 1n }]);
    await settle(calls[0], { ok: false, error: "stale failure" });
    assert.equal(f.current.state.status, "loading");
    assert.equal(f.current.state.token.key, "b");
    assert.equal(f.current.refresh, oldRefresh);
    await act(() => runAction(oldRefresh));
    assert.equal(calls.length, 3);
    assert.equal(calls[2].request.token.key, "b");
    await settle(calls[2], { ok: true, value: 3n });
    await settle(calls[1], { ok: true, value: 2n });
    assert.equal(f.current.state.value, 3n);
  } finally { await f.close(); }
  assert.deepEqual(cleanups.map(token => token.generation), [1n, 2n, 3n]);
});

test("dependencies trigger replacement; fresh loader closures do not loop and refresh uses the newest closure", async () => {
  const first = pendingLoader(), second = pendingLoader();
  const f = await mount({ key: "same", load: first.load, dependencies: [1n] });
  try {
    await f.render({ key: "same", load: second.load, dependencies: [1n] });
    assert.equal(first.calls.length, 1);
    assert.equal(second.calls.length, 0);
    await f.refresh();
    assert.equal(second.calls.length, 1);
    await f.render({ key: "same", load: second.load, dependencies: [2n] });
    assert.equal(second.calls.length, 2);
    await settle(second.calls[1], { ok: true, value: "latest dependency" });
    await settle(second.calls[0], { ok: true, value: "old dependency" });
    await settle(first.calls[0], { ok: true, value: "old closure" });
    assert.equal(f.current.state.value, "latest dependency");
  } finally { await f.close(); }
});

test("unmount aborts ownership, suppresses delivery, and immediately runs cleanup registered after an await", async () => {
  const wait = deferred();
  let request, cleanups = 0;
  const load = context => action(async () => {
    request = context;
    await wait.promise;
    await runAction(context.onCleanup(action(() => cleanups++)));
    return { ok: true, value: "late" };
  });
  const f = await mount({ key: "late", load });
  const resource = f.current;
  await f.close();
  assert.equal(request.signal.aborted, true);
  assert.equal(runAction(request.cancelled), true);
  const count = f.renders.length;
  await act(async () => { wait.resolve(); await wait.promise; });
  assert.equal(cleanups, 1);
  assert.equal(f.renders.length, count);
  assert.equal(runAction(resource.read).status, "idle");
  await act(() => runAction(resource.refresh));
  assert.equal(f.renders.length, count);
});

test("typed loader errors and host exceptions remain distinct and refresh can recover", async () => {
  const domainError = { code: "conflict", currentRevision: 987654321987654321n };
  const bad = pendingLoader();
  const f = await mount({ key: "errors", load: bad.load });
  try {
    await settle(bad.calls[0], { ok: false, error: domainError });
    assert.equal(f.current.state.error.kind, "loader");
    assert.equal(f.current.state.error.error, domainError);
    await f.refresh();
    const thrown = new Error("transport broke");
    await act(async () => { bad.calls[1].reject(thrown); await bad.calls[1].promise.catch(() => {}); });
    // The thrown value rides along so an adapter can recognise typed transport failures.
    assert.deepEqual(f.current.state.error, { kind: "exception", message: "transport broke", error: thrown });
    await f.render({ key: "errors", load: () => action(() => { throw new Error("sync broke"); }) });
    await f.refresh();
    assert.equal(f.current.state.error.kind, "exception");
    assert.equal(f.current.state.error.message, "sync broke");
    assert.equal(f.current.state.error.error.message, "sync broke");
    await f.render({ key: "errors", load: () => action(() => ({ ok: true, value: "recovered" })) });
    await f.refresh();
    assert.equal(f.current.state.value, "recovered");
  } finally { await f.close(); }
});

test("disabled resources stay idle and disabling a pending request suppresses its late rejection", async () => {
  const loader = pendingLoader();
  const f = await mount({ key: "optional", load: loader.load, enabled: false });
  try {
    assert.equal(f.current.state.status, "idle");
    await f.refresh();
    assert.equal(loader.calls.length, 0);
    await f.render({ key: "optional", load: loader.load, enabled: true });
    assert.equal(loader.calls.length, 1);
    await f.render({ key: "optional", load: loader.load, enabled: false });
    assert.equal(f.current.state.status, "idle");
    assert.equal(loader.calls[0].request.signal.aborted, true);
    await act(async () => { loader.calls[0].reject(new Error("late")); await loader.calls[0].promise.catch(() => {}); });
    assert.equal(f.current.state.status, "idle");
    await f.render({ key: "optional", load: loader.load, enabled: true });
    assert.equal(loader.calls[1].request.token.generation, 2n);
    await settle(loader.calls[1], { ok: true, value: "enabled" });
    assert.equal(f.current.state.value, "enabled");
  } finally { await f.close(); }
});

test("Strict Mode cleans replayed requests and accepts only the active generation", async () => {
  const calls = [], releases = [];
  const load = request => action(() => {
    const pending = deferred();
    calls.push({ request, ...pending });
    runAction(request.onCleanup(action(() => releases.push(request.token.generation))));
    return pending.promise;
  });
  const f = await mount({ key: "strict", load }, { strict: true });
  try {
    assert.ok(calls.length >= 2);
    const last = calls.at(-1);
    assert.equal(calls.filter(call => !call.request.signal.aborted).length, 1);
    for (const old of calls.slice(0, -1)) await settle(old, { ok: true, value: "old" });
    assert.equal(f.current.state.status, "loading");
    await settle(last, { ok: true, value: "active" });
    assert.equal(f.current.state.value, "active");
  } finally { await f.close(); }
  assert.equal(new Set(releases).size, calls.length);
  assert.equal(releases.length, calls.length);
});

test("cleanup failures are reported without dropping the other cleanup registrations", async () => {
  const errors = [], released = [];
  const extension = createResourceHooks(React, runtime, { onCleanupError: error => errors.push(error.message) });
  const f = await mount({ key: "cleanup", load: request => action(() => {
    runAction(request.onCleanup(action(() => released.push("first"))));
    runAction(request.onCleanup(action(() => { throw new Error("cleanup failed"); })));
    runAction(request.onCleanup(action(() => released.push("last"))));
    return { ok: true, value: "ready" };
  }) }, { extension });
  await f.close();
  assert.deepEqual(released, ["last", "first"]);
  assert.deepEqual(errors, ["cleanup failed"]);
});

test("resource dependencies have a fixed shape and malformed loader results become exception failures", async () => {
  const load = () => action(() => undefined);
  const f = await mount({ key: "shape", load, dependencies: [1] });
  try {
    assert.equal(f.current.state.status, "failure");
    assert.match(f.current.state.error.message, /Resource loader must return/);
    await assert.rejects(f.render({ key: "shape", load, dependencies: [] }), error => error instanceof HookPlacementError);
  } finally { await f.close(); }
});

test("resource intrinsic preserves explicit request/result/state codecs and deferred read/refresh handles", async () => {
  const encoded = value => ({ payload: value });
  const decode = value => value.payload;
  const abi = {
    key: decode, string: decode, bool: decode, dependencies: decode,
    call: (fn, args) => fn(...args),
    request: encoded,
    result: decode,
    state: encoded,
    resource: encoded,
    unit: () => encoded("unit"),
  };
  assert.throws(() => createResourceIntrinsic(runtime, resources, {}), /abi.key/);
  const intrinsic = createResourceIntrinsic(runtime, resources, abi);
  let seen;
  const extension = { useResource: (key, load, deps, enabled, site) => runtime.mapHook(decode,
    intrinsic(encoded(key), request => {
      seen = decode(request);
      return action(() => encoded({ ok: true, value: encoded("typed value") }));
    }, encoded(deps), encoded(enabled), encoded(site))) };
  const f = await mount({ key: "abi", load: null }, { extension });
  try {
    assert.equal(seen.token.key, "abi");
    assert.equal(decode(f.current.state).status, "success");
    assert.deepEqual(decode(f.current.state).value, encoded("typed value"));
    assert.equal(decode(runAction(f.current.read)).status, "success");
    await act(() => { assert.deepEqual(runAction(f.current.refresh), encoded("unit")); });
    assert.equal(seen.token.generation, 2n);
  } finally { await f.close(); }
});

test("refresh requested from cleanup keeps the newer request without leaking a superseded generation", async () => {
  const calls = [], released = [];
  let refresh;
  const load = request => action(() => {
    const pending = deferred();
    calls.push({ request, ...pending });
    runAction(request.onCleanup(action(() => {
      released.push(request.token.generation);
      if (refresh) runAction(refresh);
    })));
    return pending.promise;
  });
  const f = await mount({ key: "reentrant", load });
  refresh = f.current.refresh;
  try {
    await f.refresh();
    assert.equal(calls.length, 2);
    assert.deepEqual(released, [1n]);
    await settle(calls[1], { ok: true, value: "latest" });
    await settle(calls[0], { ok: true, value: "stale" });
    assert.equal(f.current.state.value, "latest");
  } finally { await f.close(); }
  assert.deepEqual(released, [1n, 2n]);
});
