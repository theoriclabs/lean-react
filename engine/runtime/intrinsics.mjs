import { action, pureAction, bindAction, mapAction, pureHook } from "./react.mjs";

/**
 * Semantic intrinsic bindings, NOT a LeanJS ABI implementation.
 * The compiler must erase arguments and supply every codec in INTRINSICS.md.
 * Values of Action, Hook, Element, Component and Context are opaque host handles.
 */
export function createIntrinsicAdapter(runtime, abi) {
  for (const name of ["call", "closure", "record", "string", "array", "key", "dependencies", "attribute", "unit", "componentIdentity"]) {
    if (typeof abi?.[name] !== "function") throw new TypeError(`LeanReact intrinsic adapter requires abi.${name}`);
  }
  const call = (fn, ...args) => abi.call(fn, args);
  const unitAction = work => mapAction(() => abi.unit(), work);
  const unitHook = work => runtime.mapHook(() => abi.unit(), work);
  const components = new Map();
  const contexts = new Map();
  const providers = new Map();
  function makeProvider(context) {
    return runtime.component(props => {
      if (typeof abi.providerProps !== "function") throw new TypeError("LeanReact.provider requires abi.providerProps");
      const decoded = abi.providerProps(props);
      return pureHook(runtime.provide(context, decoded.value, decoded.children));
    }, { name: `${context.name}.Provider` });
  }
  function adaptAttribute(value, props) {
    const attr = abi.attribute(value);
    switch (attr.kind) {
      case "string": case "bool": props[attr.name] = attr.value; break;
      case "press": props.onClick = runtime.onClick(event => call(attr.handler, abi.record("LeanReact.PressEvent", event))); break;
      case "change": props.onChange = runtime.onChange(event => call(attr.handler, abi.record("LeanReact.ChangeEvent", event))); break;
      case "keyDown": props.onKeyDown = runtime.onKeyDown(event => call(attr.handler, abi.record("LeanReact.KeyEvent", event))); break;
      default: throw new TypeError(`Unknown decoded LeanReact attribute: ${attr.kind}`);
    }
  }
  return Object.freeze({
    "LeanReact.Action.pure": value => pureAction(value),
    "LeanReact.Action.bind": (first, next) => bindAction(first, value => call(next, value)),
    "LeanReact.Action.map": (f, work) => mapAction(value => call(f, value), work),
    "LeanReact.Hook.pure": value => pureHook(value),
    "LeanReact.Hook.bind": (first, next) => runtime.bindHook(first, value => call(next, value)),
    "LeanReact.Hook.map": (f, work) => runtime.mapHook(value => call(f, value), work),
    "LeanReact.component": render => {
      const identity = abi.componentIdentity(render);
      if (identity === undefined || identity === null) throw new TypeError("A stable component identity is required from the compiler adapter");
      if (!components.has(identity)) components.set(identity, runtime.component(props => call(render, props)));
      return components.get(identity);
    },
    "LeanReact.Component.named": (name, Component) => runtime.nameComponent(abi.string(name), Component),
    "LeanReact.element": (Component, props) => runtime.element(Component, props),
    "LeanReact.text": value => runtime.text(abi.string(value)),
    "LeanReact.empty": () => runtime.empty,
    "LeanReact.fragment": children => runtime.fragment(abi.array(children)),
    "LeanReact.keyed": (key, child) => runtime.keyed(abi.key(key), child),
    "LeanReact.keyedEach": (items, keyOf, row) => runtime.keyedEach(abi.array(items), value => abi.key(call(keyOf, value)), value => call(row, value)),
    "LeanReact.node": (tag, attributes, children) => {
      const props = {};
      for (const attribute of abi.array(attributes)) adaptAttribute(attribute, props);
      return runtime.dom(abi.string(tag), props, abi.array(children));
    },
    "LeanReact.useState": (initial, site) => runtime.mapHook(state => abi.record("LeanReact.State", {
      value: state.value,
      set: abi.closure(1, value => unitAction(state.set(value))),
      modify: abi.closure(1, update => unitAction(state.modify(previous => call(update, previous)))),
      read: state.read,
    }), runtime.useState(initial, abi.string(site))),
    "LeanReact.useEffect": (dependencies, setup, site) => unitHook(runtime.useEffect(abi.dependencies(dependencies), setup, abi.string(site))),
    "LeanReact.createContext": (name, initial) => {
      const id = abi.string(name);
      if (!contexts.has(id)) {
        const context = runtime.createContext(id, initial);
        contexts.set(id, context);
        providers.set(context, makeProvider(context));
      }
      return contexts.get(id);
    },
    "LeanReact.useContext": (context, site) => runtime.useContext(context, abi.string(site)),
    "LeanReact.provide": (context, value, child) => runtime.provide(context, value, child),
    "LeanReact.provider": context => {
      if (!providers.has(context)) throw new TypeError("Expected a context created by this intrinsic adapter");
      return providers.get(context);
    },
  });
}

/** A foreign host service must return Action handles and explicitly encode its result. */
export const hostAction = (execute, encode) => action(() => {
  const value = execute();
  return value != null && typeof value.then === "function" ? Promise.resolve(value).then(encode) : encode(value);
});
