// Host values only. No Lean constructor, arity, or erasure convention is assumed.
const actionTag = Symbol("LeanReact.Action");
let renderDepth = 0;

export function action(execute) {
  if (typeof execute !== "function") throw new TypeError("action expects a deferred function");
  return Object.freeze({ [actionTag]: true, execute });
}
export const isAction = value => value?.[actionTag] === true;
export const pureAction = value => action(() => value);
const isPromise = value => value != null && typeof value.then === "function";
export function bindAction(first, next) {
  return action(() => {
    const value = runAction(first);
    return isPromise(value) ? Promise.resolve(value).then(x => runAction(next(x))) : runAction(next(value));
  });
}
export const mapAction = (f, work) => bindAction(work, value => pureAction(f(value)));
export function catchAction(work, recover) {
  return action(() => {
    try {
      const value = runAction(work);
      return isPromise(value) ? Promise.resolve(value).catch(error => runAction(recover(error))) : value;
    } catch (error) { return runAction(recover(error)); }
  });
}
export function runAction(work) {
  if (renderDepth) throw new Error("LeanReact actions cannot execute during render; attach an event or managed effect");
  if (!isAction(work)) throw new TypeError("Expected a LeanReact Action");
  return work.execute();
}
// Internal phase boundary shared across runtime instances.
export function duringRender(render) {
  renderDepth++;
  try { return render(); } finally { renderDepth--; }
}
export const isRendering = () => renderDepth > 0;
