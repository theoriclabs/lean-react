// Explicit adapter between LeanJS ABI v0 and the host-only React runtime.
import * as React from 'react';
import { createRuntime, pureHook, pureAction, bindAction, mapAction, catchAction, runAction } from '../runtime/react.mjs';
import { createResourceHooks } from '../runtime/resources.mjs';
import { createCellHooks } from '../runtime/cells.mjs';

export const runtime = createRuntime(React);
const resources = createResourceHooks(React, runtime);
const cells = createCellHooks(React, runtime);
const ctor = (tag, fields = []) => ({ tag, fields });
const unit = ctor('Unit.unit');
export const erased = null;
const bool = value => ctor(value ? 'Bool.true' : 'Bool.false');
const fromBool = value => value?.tag === 'Bool.true';
const keyText = value => value.fields[0];
const descriptorComponents = new WeakMap();
const ComponentHost = runtime.component(({ descriptor, props }) => descriptor.fields[0](props), { name: 'LeanComponent' });
function hostComponent(descriptor) {
  if (!descriptorComponents.has(descriptor)) {
    function CompiledComponent({ leanProps }) {
      return runtime.element(ComponentHost, { descriptor, props: leanProps });
    }
    CompiledComponent.displayName = descriptor.fields[1];
    descriptorComponents.set(descriptor, CompiledComponent);
  }
  return descriptorComponents.get(descriptor);
}

export const actionPure = (_type, value) => pureAction(value);
export const actionBind = (_a, _b, first, next) => bindAction(first, next);
export const actionMap = (_a, _b, transform, value) => mapAction(transform, value);
export const actionCatch = (_type, value, recover) => catchAction(value,
  error => recover(ctor('IO.Error.userError', [error instanceof Error ? error.message : String(error)])));
export const hookPure = (_type, value) => pureHook(value);
export const hookBind = (_a, _b, first, next) => runtime.bindHook(first, next);
export const hookMap = (_a, _b, transform, value) => runtime.mapHook(transform, value);
export const useCell = (_type, initial, site) => cells.useCell(initial, site);
export const cellRead = (_type, cell) => cell.read;
export const cellModifyGet = (_a, _b, cell, transition) => cell.modifyGet(previous => {
  const pair = transition(previous);
  if (pair?.tag !== 'Prod.mk' || pair.fields.length !== 2) throw new TypeError('Cell transition must return a Lean pair');
  return { result: pair.fields[0], nextValue: pair.fields[1] };
});
export const useState = (_type, initial, site) => runtime.mapHook(state => ctor('LeanReact.State.mk', [
  state.value,
  value => mapAction(() => unit, state.set(value)),
  update => mapAction(() => unit, state.modify(update)),
  state.read,
]), runtime.useState(initial, site));
export const useEffect = (dependencies, setup, site) => runtime.mapHook(() => unit,
  runtime.useEffect(dependencies.map(dependency => {
    const value = dependency.fields[0];
    return dependency.tag === 'LeanReact.Dependency.bool' ? fromBool(value) : value;
  }), setup, site));

const requestSignals = new WeakMap();
const tokenValue = token => ctor('LeanReact.ResourceToken.mk', [ctor('LeanReact.Key.mk', [token.key]), token.generation]);
function resourceState(value) {
  const tag = `LeanReact.ResourceState.${value.status}`;
  if (value.status === 'idle') return ctor(tag);
  const token = tokenValue(value.token);
  if (value.status === 'loading') return ctor(tag, [token]);
  if (value.status === 'success') return ctor(tag, [token, value.value]);
  const failure = value.error.kind === 'loader'
    ? ctor('LeanReact.ResourceFailure.loader', [value.error.error])
    : ctor('LeanReact.ResourceFailure.exception', [value.error.message]);
  return ctor(tag, [token, failure]);
}
export const resourceSignal = request => requestSignals.get(request);
export function useResource(_valueType, _errorType, key, loader, dependencies, enabled, site) {
  const load = request => {
    const descriptor = ctor('LeanReact.ResourceRequest.mk', [
      tokenValue(request.token), mapAction(bool, request.cancelled),
      cleanup => mapAction(() => unit, request.onCleanup(cleanup)),
    ]);
    requestSignals.set(descriptor, request.signal);
    return mapAction(result => {
      if (result.tag === 'Except.ok') return { ok: true, value: result.fields[0] };
      if (result.tag === 'Except.error') return { ok: false, error: result.fields[0] };
      throw new TypeError('Compiled resource loader did not return Except');
    }, loader(descriptor));
  };
  const deps = dependencies.map(item => item.tag === 'LeanReact.Dependency.bool' ? fromBool(item.fields[0]) : item.fields[0]);
  return runtime.mapHook(value => ctor('LeanReact.Resource.mk', [
    resourceState(value.state), mapAction(() => unit, value.refresh), mapAction(resourceState, value.read),
  ]), resources.useResource(keyText(key), load, deps, fromBool(enabled), site));
}
export const component = (_propsType, render) => ctor('LeanReact.Component.mk', [render, 'Anonymous']);
export const componentNamed = (_propsType, name, value) => ctor('LeanReact.Component.mk', [value.fields[0], name]);
export const element = (_propsType, descriptor, props) => runtime.foreignElement(hostComponent(descriptor), { leanProps: props });
export const text = value => runtime.text(value);
export const fragment = children => runtime.fragment(children);
export const empty = null;
export const keyed = (key, child) => runtime.keyed(keyText(key), child);
export const keyedEach = (_type, items, key, row) => runtime.keyedEach(items, item => keyText(key(item)), row);

function eventPayload(tag, value) {
  if (tag === 'LeanReact.ChangeEvent.mk') return ctor(tag, [value.value, bool(value.checked)]);
  const flags = [bool(value.alt), bool(value.ctrl), bool(value.metaKey), bool(value.shift)];
  return ctor(tag, tag === 'LeanReact.KeyEvent.mk' ? [value.key, ...flags] : flags);
}
export function node(tag, attributes, children) {
  const props = {};
  for (const attribute of attributes) {
    const [name, value] = attribute.fields;
    switch (attribute.tag) {
      case 'LeanReact.Attribute.string': props[name] = value; break;
      case 'LeanReact.Attribute.bool': props[name] = fromBool(value); break;
      case 'LeanReact.Attribute.press': props.onClick = runtime.onClick(payload => name(eventPayload('LeanReact.PressEvent.mk', payload))); break;
      case 'LeanReact.Attribute.change': props.onChange = runtime.onChange(payload => name(eventPayload('LeanReact.ChangeEvent.mk', payload))); break;
      case 'LeanReact.Attribute.keyDown': props.onKeyDown = runtime.onKeyDown(payload => name(eventPayload('LeanReact.KeyEvent.mk', payload))); break;
      default: throw new TypeError(`Unknown LeanReact attribute: ${attribute.tag}`);
    }
  }
  return runtime.dom(tag, props, children);
}

const contexts = new WeakMap();
export function createContext(_type, _typeName, name, defaultValue) {
  const descriptor = ctor('LeanReact.Context.mk', [name, defaultValue, null, null]);
  contexts.set(descriptor, runtime.createContext(name, defaultValue));
  return descriptor;
}
function hostContext(descriptor) {
  const context = contexts.get(descriptor);
  if (!context) throw new TypeError('Context was not created through the LeanReact compiler adapter');
  return context;
}
export const useContext = (_type, descriptor, site) => runtime.useContext(hostContext(descriptor), site);
export const provide = (_type, descriptor, value, child) => runtime.provide(hostContext(descriptor), value, child);

export function mountElement(descriptor, props = unit) { return element(null, descriptor, props); }
export function asReactComponent(descriptor, decodeProps = value => value) {
  function ExportedLeanComponent(props) { return mountElement(descriptor, decodeProps(props)); }
  ExportedLeanComponent.displayName = descriptor.fields[1];
  return ExportedLeanComponent;
}
export { ctor, unit, bool, fromBool, runAction };
