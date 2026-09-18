// Lean-facing service adapters over the browser transport. Loaders built here are cancellable:
// the resource's AbortSignal reaches `fetch`, so unmount, refresh, and scope changes abort the request.
import { action } from '../runtime/actions.mjs';
import { resourceSignal } from '../adapters/leanjs-react.mjs';

/** A `useResource` loader over an HTTP client: `(request, args) => Action`, where `request` is the Lean
 * `ResourceRequest` handed to the loader and `args` are encoded by `encodeArgs` into the operation input.
 * The Action resolves to the client's `{ok:true, value}` / `{ok:false, error}` result and rejects with
 * `CallFailure` (kind `cancelled` after an abort), which `useResource` reports as `ResourceFailure.call`. */
export function resourceLoader(client, identity, encodeArgs = () => null) {
  if (typeof client?.call !== 'function') throw new TypeError('resourceLoader requires a client with call(identity, input, options)');
  return (request, args) => action(() => client.call(identity, encodeArgs(args), { signal: resourceSignal(request) }));
}
