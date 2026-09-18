import test from "node:test";
import assert from "node:assert/strict";
import { JSDOM } from "jsdom";
import { createRuntime, hook, pureHook, action, pureAction, bindAction, runAction, HookPlacementError } from "../../engine/runtime/react.mjs";

const window = new JSDOM("<!doctype html><html><body></body></html>", { url: "http://localhost" }).window;
globalThis.window = window;
globalThis.document = window.document;
globalThis.HTMLElement = window.HTMLElement;
globalThis.IS_REACT_ACT_ENVIRONMENT = true;
const React = await import("react");
const { createRoot } = await import("react-dom/client");
const { act } = React;
const rt = createRuntime(React);
const { component, element, dom, text, keyedEach, useState, useEffect, runHook, onPress } = rt;

async function fixture(initial) {
  const container = document.createElement("div");
  document.body.append(container);
  const root = createRoot(container);
  await act(() => root.render(initial));
  return {
    container,
    render: async value => { await act(() => root.render(value)); },
    click: selector => act(() => container.querySelector(selector).dispatchEvent(new window.MouseEvent("click", { bubbles: true }))),
    close: async () => { await act(() => root.unmount()); container.remove(); },
  };
}

test("events defer actions, batch functional updates, keep state, and capture new callback props", async () => {
  const outputs = [];
  const Counter = component(props => hook(() => {
    const state = runHook(useState(0n, "count"));
    const work = bindAction(state.modify(x => x + 1n), () => bindAction(state.modify(x => x + 1n), () => props.onChange(props.label)));
    return dom("button", { onClick: onPress(work) }, [text(`${props.label}:${state.value}`)]);
  }), { name: "Counter" });
  const props = label => ({ label, onChange: label => action(() => outputs.push(label)) });
  const child = element(Counter, props("a"));
  assert.deepEqual(outputs, []);
  const f = await fixture(child);
  try {
    assert.equal(f.container.textContent, "a:0");
    assert.deepEqual(outputs, []);
    await f.click("button");
    assert.equal(f.container.textContent, "a:2");
    await f.render(element(Counter, props("b")));
    await f.click("button");
    assert.equal(f.container.textContent, "b:4");
    assert.deepEqual(outputs, ["a", "b"]);
  } finally { await f.close(); }
});

test("keyed reorder preserves child state, slots remain callbacks, and children render separately", async () => {
  let renders = 0;
  const Row = component(props => hook(() => {
    renders++;
    const state = runHook(useState(0, "row"));
    return dom("button", { id: props.id, onClick: onPress(state.modify(n => n + 1)) }, [props.slot(props.id), text(`:${state.value}`)]);
  }));
  const List = component(props => pureHook(keyedEach(props.items, x => x, x => element(Row, { id: x, slot: props.slot }))));
  const props = items => ({ items, slot: id => dom("strong", {}, [text(id.toUpperCase())]) });
  const tree = element(List, props(["a", "b"]));
  assert.equal(renders, 0);
  const f = await fixture(tree);
  try {
    await f.click("#a");
    const before = f.container.querySelector("#a");
    await f.render(element(List, props(["b", "a"])));
    assert.equal(f.container.textContent, "B:0A:1");
    assert.equal(f.container.querySelector("#a"), before);
  } finally { await f.close(); }
});

test("one custom hook composes in two layouts with independent state", async () => {
  const useCounter = initial => rt.namedHook("useCounter", rt.mapHook(s => ({ value: s.value, increment: s.modify(n => n + 1) }), useState(initial, "value")));
  const Compact = component(() => rt.mapHook(model => dom("button", { id: "compact", onClick: onPress(model.increment) }, [text(String(model.value))]), useCounter(1)));
  const Wide = component(() => rt.mapHook(model => dom("section", {}, [dom("button", { id: "wide", onClick: onPress(model.increment) }, [text(String(model.value))])]), useCounter(10)));
  const f = await fixture(rt.fragment([element(Compact, null), element(Wide, null)]));
  try {
    await f.click("#compact");
    assert.equal(f.container.querySelector("#compact").textContent, "2");
    assert.equal(f.container.querySelector("#wide").textContent, "10");
    await f.click("#wide");
    assert.equal(f.container.querySelector("#wide").textContent, "11");
  } finally { await f.close(); }
});

test("controlled values and an uncontrolled wrapper reuse the same picker", async () => {
  const Picker = component(props => pureHook(dom("button", { id: props.id, onClick: onPress(props.onChange(!props.selected)) }, [text(String(props.selected))])));
  const Owned = component(() => hook(() => {
    const state = runHook(useState(false, "selection"));
    return element(Picker, { id: "owned", selected: state.value, onChange: state.set });
  }));
  const received = [];
  const controlled = value => element(Picker, { id: "controlled", selected: value, onChange: x => action(() => received.push(x)) });
  const f = await fixture(rt.fragment([controlled(false), element(Owned, null)]));
  try {
    await f.click("#controlled");
    assert.deepEqual(received, [true]);
    assert.equal(f.container.querySelector("#controlled").textContent, "false");
    await f.render(rt.fragment([controlled(true), element(Owned, null)]));
    await f.click("#owned");
    assert.equal(f.container.querySelector("#controlled").textContent, "true");
    assert.equal(f.container.querySelector("#owned").textContent, "true");
  } finally { await f.close(); }
});

test("typed context bridge scopes function-bearing services, defaults, updates, and provider identity", async () => {
  const context = rt.createContext("Formatter", { format: x => `default:${x}` });
  const Consumer = component(() => rt.mapHook(service => text(service.format("value")), rt.useContext(context, "service")));
  const Provider = rt.provider(context);
  assert.equal(rt.provider(context), Provider);
  const tree = prefix => rt.fragment([
    element(Consumer, null),
    element(Provider, { value: { format: x => `${prefix}:${x}` }, children: rt.fragment([
      element(Consumer, null), rt.provide(context, { format: x => `inner:${x}` }, element(Consumer, null)),
    ]) }),
  ]);
  const f = await fixture(tree("outer"));
  try {
    assert.equal(f.container.textContent, "default:valueouter:valueinner:value");
    await f.render(tree("changed"));
    assert.equal(f.container.textContent, "default:valuechanged:valueinner:value");
  } finally { await f.close(); }
});

test("managed effects run after render, compare dependencies, and clean up on change and unmount", async () => {
  const log = [];
  const Effectful = component(props => hook(() => {
    log.push(`render:${props.id}`);
    runHook(useEffect([props.id], action(() => {
      log.push(`setup:${props.id}`);
      return action(() => log.push(`cleanup:${props.id}`));
    }), "subscription"));
    return text(props.id);
  }));
  const initial = element(Effectful, { id: "a" });
  assert.deepEqual(log, []);
  const f = await fixture(initial);
  try {
    assert.deepEqual(log, ["render:a", "setup:a"]);
    await f.render(element(Effectful, { id: "a" }));
    assert.deepEqual(log, ["render:a", "setup:a", "render:a"]);
    await f.render(element(Effectful, { id: "b" }));
    assert.deepEqual(log.slice(-3), ["render:b", "cleanup:a", "setup:b"]);
  } finally { await f.close(); }
  assert.equal(log.at(-1), "cleanup:b");
});

test("Strict Mode balances lifecycle ownership and does not execute event actions on render", async () => {
  let live = 0, setups = 0, clicks = 0;
  const Child = component(() => hook(() => {
    runHook(useEffect([], action(() => { setups++; live++; return action(() => live--); }), "resource"));
    return dom("button", { onClick: onPress(action(() => clicks++)) }, ["press"]);
  }));
  const f = await fixture(React.createElement(React.StrictMode, null, element(Child, null)));
  try {
    assert.ok(setups >= 2);
    assert.equal(live, 1);
    assert.equal(clicks, 0);
    await f.click("button");
    assert.equal(clicks, 1);
  } finally { await f.close(); }
  assert.equal(live, 0);
});

test("async effect cleanup is retained when setup resolves after unmount", async () => {
  let resolve;
  const pending = new Promise(done => { resolve = done; });
  let cleanups = 0;
  const Child = component(() => rt.bindHook(useEffect([], action(() => pending), "async"), () => pureHook(text("pending"))));
  const f = await fixture(element(Child, null));
  await f.close();
  await act(async () => { resolve(action(() => cleanups++)); await pending; });
  assert.equal(cleanups, 1);
});

test("DOM adapters snapshot event data before async work and actual checkbox events update state", async () => {
  let observed;
  const raw = { currentTarget: { value: "first", checked: true } };
  rt.onChange(payload => action(async () => { await Promise.resolve(); observed = payload; }))(raw);
  raw.currentTarget.value = "mutated";
  await Promise.resolve();
  assert.deepEqual(observed, { value: "first", checked: true });
  assert.ok(Object.isFrozen(observed));
  const Check = component(() => hook(() => {
    const state = runHook(useState(false, "checked"));
    return dom("input", { type: "checkbox", checked: state.value, onChange: rt.onChange(e => state.set(e.checked)) });
  }));
  const f = await fixture(element(Check, null));
  try {
    await f.click("input");
    assert.equal(f.container.querySelector("input").checked, true);
  } finally { await f.close(); }
});

test("form submit is always default-prevented and key handlers decide the default synchronously", async () => {
  const log = [];
  const errors = [];
  const local = createRuntime(React, { onActionError: error => errors.push(error.message) });
  const Form = local.component(() => pureHook(local.dom("form", { onSubmit: local.onSubmit(action(() => log.push("submit"))) }, [
    local.dom("input", { id: "sync", onKeyDown: local.onKeyDown(e => pureAction(e.ctrl && e.key === "s" ? "preventDefault" : "continue")) }),
    local.dom("input", { id: "async", onKeyDown: local.onKeyDown(() => action(async () => "preventDefault")) }),
  ])));
  const f = await fixture(local.element(Form, null));
  try {
    const dispatch = (selector, event) => { let prevented; act(() => { f.container.querySelector(selector).dispatchEvent(event); prevented = event.defaultPrevented; }); return prevented; };
    assert.equal(dispatch("form", new window.Event("submit", { bubbles: true, cancelable: true })), true);
    assert.deepEqual(log, ["submit"]);
    const key = init => new window.KeyboardEvent("keydown", { bubbles: true, cancelable: true, ...init });
    assert.equal(dispatch("#sync", key({ key: "s", ctrlKey: true })), true);
    assert.equal(dispatch("#sync", key({ key: "s" })), false);
    assert.equal(dispatch("#async", key({ key: "s" })), false);
    await act(async () => { await Promise.resolve(); });
    assert.match(errors[0], /preventDefault resolved asynchronously/);
  } finally { await f.close(); }
});

test("focus, blur, input, paste and scroll adapters snapshot their payloads", async () => {
  const seen = [];
  const record = kind => payload => action(() => seen.push([kind, payload]));
  const Field = component(() => pureHook(dom("textarea", {
    id: "field", defaultValue: "typed",
    onFocus: rt.onFocus(record("focus")), onBlur: rt.onBlur(record("blur")), onInput: rt.onInput(record("input")),
    onPaste: rt.onPaste(record("paste")), onScroll: rt.onScroll(record("scroll")),
    onMouseEnter: rt.onMouseEnter(record("enter")), onMouseLeave: rt.onMouseLeave(record("leave")),
  })));
  const f = await fixture(element(Field, null));
  try {
    const field = f.container.querySelector("#field");
    await act(() => { field.focus(); field.blur(); });
    assert.deepEqual(seen.splice(0), [["focus", { value: "typed" }], ["blur", { value: "typed" }]]);
    const paste = new window.Event("paste", { bubbles: true, cancelable: true });
    const clipboard = { "text/plain": "copied", "text/html": "" };
    Object.defineProperty(paste, "clipboardData", { value: { getData: type => clipboard[type] } });
    await act(() => field.dispatchEvent(paste));
    clipboard["text/plain"] = "changed";
    assert.deepEqual(seen.splice(0), [["paste", { text: "copied", html: null }]]);
    await act(() => field.dispatchEvent(new window.Event("scroll", { bubbles: false })));
    assert.deepEqual(seen.splice(0), [["scroll", { scrollTop: 0, scrollLeft: 0 }]]);
    await act(() => field.dispatchEvent(new window.MouseEvent("mouseover", { bubbles: true, shiftKey: true })));
    assert.deepEqual(seen.splice(0), [["enter", { alt: false, ctrl: false, metaKey: false, shift: true }]]);
    assert.ok(seen.every(([, payload]) => Object.isFrozen(payload)));
  } finally { await f.close(); }
});

test("function-valued state is stored as a value instead of invoked as an initializer or updater", async () => {
  const initial = () => "first";
  const next = () => "second";
  const Child = component(() => hook(() => {
    const state = runHook(useState(initial, "function"));
    return dom("button", { onClick: onPress(state.set(next)) }, [text(state.value())]);
  }));
  const f = await fixture(element(Child, null));
  try {
    assert.equal(f.container.textContent, "first");
    await f.click("button");
    assert.equal(f.container.textContent, "second");
  } finally { await f.close(); }
});

test("foreign components have an explicit bridge and receive live callbacks and render props", async () => {
  let clicked = 0;
  function Foreign({ content, onClick }) { return React.createElement("button", { onClick }, content("slot")); }
  const LeanSide = component(() => pureHook(rt.foreignElement(Foreign, {
    content: word => dom("b", {}, [text(word)]), onClick: onPress(action(() => clicked++)),
  })));
  assert.throws(() => element(Foreign, {}), /foreignElement/);
  const f = await fixture(element(LeanSide, null));
  try { await f.click("button"); assert.equal(clicked, 1); assert.equal(f.container.textContent, "slot"); }
  finally { await f.close(); }
});

test("imperative handles fire onReady once per mount, resolve to unmounted results, and remount under a new key", async () => {
  const log = [];
  let handle;
  function Widget({ label, ref }) {
    React.useImperativeHandle(ref, () => ({ shout: word => `${label}:${word.toUpperCase()}`, later: async () => "later" }), [label]);
    return React.createElement("output", null, label);
  }
  const lifecycle = {
    onReady: received => action(() => { handle = received; log.push("ready"); }),
    onGone: action(() => log.push("gone")),
    adapt: (invoke, alive) => ({ shout: word => invoke("shout", [word]), later: invoke("later"), alive }),
  };
  const view = key => React.createElement(React.Fragment, { key }, rt.handleElement(Widget, { label: key }, lifecycle));
  assert.throws(() => rt.handleElement(Widget, {}, {}), /onReady/);
  const f = await fixture(view("a"));
  try {
    assert.deepEqual(log, ["ready"]);
    assert.equal(runAction(handle.alive), true);
    assert.deepEqual(runAction(handle.shout("hi")), { ok: true, value: "a:HI" });
    assert.deepEqual(await runAction(handle.later), { ok: true, value: "later" });
    const first = handle;
    await f.render(view("b"));
    assert.deepEqual(log, ["ready", "gone", "ready"]);
    assert.notEqual(handle, first);
    assert.equal(runAction(first.alive), false);
    assert.deepEqual(runAction(first.shout("stale")), { ok: false });
    assert.deepEqual(runAction(handle.shout("fresh")), { ok: true, value: "b:FRESH" });
  } finally { await f.close(); }
  assert.deepEqual(log, ["ready", "gone", "ready", "gone"]);
  assert.deepEqual(runAction(handle.later), { ok: false });
});

test("hook trace diagnostics reject conditional removal and a supplied plan rejects the first render", async () => {
  const Conditional = component(props => hook(() => {
    if (props.enabled) runHook(useState(0, "conditional"));
    return text("child");
  }), { name: "Conditional" });
  const f = await fixture(element(Conditional, { enabled: true }));
  try {
    await assert.rejects(f.render(element(Conditional, { enabled: false })), error => error instanceof HookPlacementError && /Conditional/.test(error.message));
  } finally { await f.close(); }
  const Planned = component(() => pureHook(text("empty")), { name: "Planned", hookPlan: [{ kind: "state", site: "required" }] });
  const empty = await fixture(null);
  try { await assert.rejects(empty.render(element(Planned, null)), /Planned expected/); }
  finally { await empty.close(); }
  assert.throws(() => runHook(useState(0)), /outside a component/);
});

test("duplicate keys and render-phase actions/definitions are rejected", async () => {
  assert.throws(() => keyedEach(["x", "x"], x => x, text), /duplicate sibling key/);
  for (const render of [
    () => hook(() => { runAction(pureAction(null)); return null; }),
    () => hook(() => { component(() => pureHook(null)); return null; }),
  ]) {
    const f = await fixture(null);
    try { await assert.rejects(f.render(element(component(render), null)), /during render/); }
    finally { await f.close(); }
  }
});

test("async event and effect errors go through the configured error boundary", async () => {
  const errors = [];
  const local = createRuntime(React, { onActionError: error => errors.push(error.message) });
  const Child = local.component(() => hook(() => {
    local.runHook(local.useEffect([], action(async () => { throw new Error("effect failure"); })));
    return local.dom("button", { onClick: local.onPress(action(async () => { throw new Error("event failure"); })) }, ["press"]);
  }));
  const f = await fixture(local.element(Child, null));
  try { await f.click("button"); assert.deepEqual(errors, ["effect failure", "event failure"]); }
  finally { await f.close(); }
});

test("intrinsic adapter requires explicit codecs and preserves closures and encoded records through React", async () => {
  const { createIntrinsicAdapter } = await import("../../engine/runtime/intrinsics.mjs");
  assert.throws(() => createIntrinsicAdapter(rt, {}), /abi.call/);
  // A deliberately test-only encoding. It makes no claim about the LeanJS ABI.
  const encode = (type, fields) => ({ testType: type, testFields: fields });
  const array = items => ({ testArray: items });
  const fn = invoke => ({ testFunction: invoke });
  const abi = {
    call: (value, args) => value.testFunction(...args),
    closure: (_arity, invoke) => fn(invoke),
    record: encode,
    string: value => value,
    array: value => value.testArray,
    key: value => value.testFields.value,
    dependencies: value => value.testArray,
    attribute: value => value.testFields,
    unit: () => encode("Unit", {}),
    componentIdentity: value => value,
    providerProps: value => value.testFields,
  };
  const bindings = createIntrinsicAdapter(rt, abi);
  const stateHook = bindings["LeanReact.useState"];
  const build = bindings["LeanReact.component"];
  const el = bindings["LeanReact.element"];
  const ctx = bindings["LeanReact.createContext"]("adapter-theme", "default");
  assert.equal(bindings["LeanReact.createContext"]("adapter-theme", "default"), ctx);
  const Consumer = build(fn(() => rt.mapHook(value => text(value), bindings["LeanReact.useContext"](ctx, "theme"))));
  const render = fn(props => rt.bindHook(stateHook(0n, "counter"), state => {
    assert.equal(state.testType, "LeanReact.State");
    const update = abi.call(state.testFields.modify, [fn(x => x + props.step)]);
    const press = fn(event => {
      assert.equal(event.testType, "LeanReact.PressEvent");
      assert.equal(event.testFields.metaKey, false);
      return update;
    });
    return pureHook(bindings["LeanReact.node"]("button", array([encode("Attribute", { kind: "press", handler: press })]), array([
      text(String(state.testFields.value)),
      el(bindings["LeanReact.provider"](ctx), encode("ProviderProps", { value: "scoped", children: el(Consumer, null) })),
    ])));
  }));
  const Counter = build(render);
  assert.equal(build(render), Counter);
  const f = await fixture(el(Counter, { step: 3n }));
  try {
    assert.equal(f.container.textContent, "0scoped");
    await f.click("button");
    assert.equal(f.container.textContent, "3scoped");
    await f.render(el(build(render), { step: 5n }));
    await f.click("button");
    assert.equal(f.container.textContent, "8scoped");
  } finally { await f.close(); }
});

test("labeled same-kind hook swaps and impure state updaters are diagnosed", async () => {
  const Swapped = component(props => hook(() => {
    runHook(useState(0, props.swap ? "b" : "a"));
    runHook(useState(0, props.swap ? "a" : "b"));
    return null;
  }));
  const f = await fixture(element(Swapped, { swap: false }));
  try { await assert.rejects(f.render(element(Swapped, { swap: true })), /hook placement/); }
  finally { await f.close(); }
  let update;
  const Child = component(() => hook(() => {
    const state = runHook(useState(0, "value"));
    update = state.modify(() => runAction(pureAction(1)));
    return text(String(state.value));
  }));
  const g = await fixture(element(Child, null));
  try { await assert.rejects(async () => { await act(() => runAction(update)); }, /cannot execute during render/); }
  finally { await g.close(); }
});

test("a retained state handle reads the latest commit while keeping its original render snapshot", async () => {
  let first;
  const Child = component(() => hook(() => {
    const state = runHook(useState(0, "value"));
    first ??= state;
    return dom("button", { onClick: onPress(state.modify(x => x + 1)) }, [text(String(state.value))]);
  }));
  const f = await fixture(element(Child, null));
  try {
    await f.click("button");
    assert.equal(first.value, 0);
    assert.equal(runAction(first.read), 1);
    await act(() => runAction(first.modify(x => x + 1)));
    assert.equal(runAction(first.read), 2);
    assert.equal(f.container.textContent, "2");
  } finally { await f.close(); }
});
