import test from "node:test";
import assert from "node:assert/strict";
import { JSDOM } from "jsdom";
import { createRuntime, pureHook, action, runAction } from "../../engine/runtime/react.mjs";
import { createRouterHooks, createBrowserHistory, createMemoryHistory, assertPath, splitLocation, segments, parseQuery, encodeQuery, parseNat } from "../../engine/runtime/router.mjs";

const window = new JSDOM("<!doctype html><html><body></body></html>", { url: "http://localhost/start" }).window;
globalThis.window = window;
globalThis.document = window.document;
globalThis.HTMLElement = window.HTMLElement;
globalThis.location = window.location;
globalThis.IS_REACT_ACT_ENVIRONMENT = true;
const React = await import("react");
const { createRoot } = await import("react-dom/client");
const { act } = React;
const rt = createRuntime(React);

test("memory history pushes, replaces, drops forward entries, and notifies on back/forward", () => {
  const history = createMemoryHistory("/a");
  const seen = [];
  const unsubscribe = history.subscribe(path => seen.push(path));
  history.push("/b"); history.push("/c"); history.back(); history.push("/d");
  assert.deepEqual(history.entries(), ["/a", "/b", "/d"]);
  history.replace("/e");
  assert.deepEqual(history.entries(), ["/a", "/b", "/e"]);
  history.back(); history.back(); history.back(); history.forward();
  assert.equal(history.current(), "/b");
  assert.deepEqual(seen, ["/b", "/c", "/b", "/d", "/e", "/b", "/a", "/b"]);
  unsubscribe();
  history.push("/f");
  assert.equal(seen.length, 8);
  assert.throws(() => history.push("https://example.com/"), /same-origin/);
  assert.throws(() => assertPath("//host/path"), /same-origin/);
});

test("browser history reads pathname+search, writes through pushState, and follows popstate", async () => {
  const history = createBrowserHistory(window);
  const seen = [];
  const unsubscribe = history.subscribe(path => seen.push(path));
  assert.equal(history.current(), "/start");
  history.push("/next?x=1");
  assert.equal(window.location.pathname + window.location.search, "/next?x=1");
  history.replace("/replaced");
  assert.equal(window.history.length >= 2, true);
  window.dispatchEvent(new window.PopStateEvent("popstate"));
  assert.deepEqual(seen, ["/next?x=1", "/replaced", "/replaced"]);
  unsubscribe();
  window.history.replaceState(null, "", "/start");
});

test("useLocation is a router hook primitive whose navigate/replace/back drive the history", async () => {
  const history = createMemoryHistory("/one");
  const router = createRouterHooks(React, rt, { history });
  let latest;
  const Screen = rt.component(() => rt.mapHook(state => { latest = state; return rt.text(state.location); }, router.useLocation("route")), { name: "Screen" });
  const container = document.createElement("div");
  document.body.append(container);
  const root = createRoot(container);
  try {
    await act(() => root.render(rt.element(Screen, null)));
    assert.equal(container.textContent, "/one");
    await act(() => runAction(latest.navigate("/two")));
    assert.equal(container.textContent, "/two");
    await act(() => runAction(latest.navigate("/two")));
    assert.deepEqual(history.entries(), ["/one", "/two"]);
    await act(() => runAction(latest.back));
    assert.equal(container.textContent, "/one");
    await act(() => runAction(latest.replace("/three")));
    assert.deepEqual(history.entries(), ["/three", "/two"]);
    assert.equal(container.textContent, "/three");
    assert.throws(() => runAction(latest.navigate("http://evil.example/")), /same-origin/);
  } finally { await act(() => root.unmount()); container.remove(); }
});

test("onNavigate handles only unmodified primary clicks on same-origin, untargeted anchors", async () => {
  let navigations = 0;
  const Links = rt.component(() => pureHook(rt.dom("nav", {}, [
    rt.dom("a", { id: "local", href: "/local", onClick: rt.onNavigate(action(() => navigations++)) }, ["local"]),
    rt.dom("a", { id: "blank", href: "/local", target: "_blank", onClick: rt.onNavigate(action(() => navigations++)) }, ["blank"]),
    rt.dom("a", { id: "external", href: "https://example.com/x", onClick: rt.onNavigate(action(() => navigations++)) }, ["external"]),
  ])));
  const container = document.createElement("div");
  document.body.append(container);
  const root = createRoot(container);
  // React's root listener runs before this document listener, so the runtime still sees an unprevented event;
  // the document listener only keeps jsdom from attempting a real navigation afterwards.
  const swallow = event => event.preventDefault();
  document.addEventListener("click", swallow);
  const click = (id, init = {}) => {
    const event = new window.MouseEvent("click", { bubbles: true, cancelable: true, button: 0, ...init });
    act(() => { container.querySelector(`#${id}`).dispatchEvent(event); });
  };
  try {
    await act(() => root.render(rt.element(Links, null)));
    click("local"); assert.equal(navigations, 1);
    click("local", { metaKey: true }); click("local", { ctrlKey: true }); click("local", { shiftKey: true }); click("local", { button: 1 });
    assert.equal(navigations, 1);
    click("blank"); click("external");
    assert.equal(navigations, 1);
  } finally { document.removeEventListener("click", swallow); await act(() => root.unmount()); container.remove(); }
});

test("URL helpers split locations, decode segments, and round-trip form-encoded queries", () => {
  assert.deepEqual(splitLocation("/tickets/42?x=1&y=2#frag"), ["/tickets/42", "x=1&y=2"]);
  assert.deepEqual(splitLocation("/plain"), ["/plain", ""]);
  assert.deepEqual(segments("/tickets/42/%C3%BC/?x=1"), ["tickets", "42", "ü"]);
  assert.deepEqual(parseQuery("?a=1&b=x%20y+z&c&d=e=f"), [["a", "1"], ["b", "x y z"], ["c", ""], ["d", "e=f"]]);
  assert.equal(encodeQuery([["a b", "1&2"], ["ü", "~*"]]), "a+b=1%262&%C3%BC=%7E*");
  assert.equal(parseNat("42"), 42n);
  assert.equal(parseNat("4a"), null);
  assert.equal(parseNat(""), null);
});
