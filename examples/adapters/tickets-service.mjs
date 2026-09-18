import { action, mapAction } from '../../engine/runtime/actions.mjs';
import { ctor } from '../../engine/adapters/leanjs-react.mjs';
import { resourceLoader } from '../../engine/LeanContract/Service.mjs';
import { createTicketsClient } from './tickets-wire.mjs';

export function createTicketsService(options = {}) {
  const client = createTicketsClient(options);
  return ctor('Examples.Tickets.TicketService.mk', [
    action(() => client.list()), input => action(() => client.save(input)),
  ]);
}

/** `WorkspaceProps.load`: the list query as a cancellable resource loader. The resource's AbortSignal reaches
 * `fetch`, so leaving the workspace or refreshing aborts the in-flight request instead of only ignoring its reply. */
export function createTicketsLoader(options = {}) {
  const client = createTicketsClient(options);
  const list = resourceLoader(client.http, client.identities.list);
  return request => mapAction(result => result.value, list(request, null));
}
