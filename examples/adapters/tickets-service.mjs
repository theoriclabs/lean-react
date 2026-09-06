import { action } from '../../engine/runtime/actions.mjs';
import { ctor } from '../../engine/adapters/leanjs-react.mjs';
import { createTicketsClient } from './tickets-wire.mjs';

export function createTicketsService(options = {}) {
  const client = createTicketsClient(options);
  return ctor('Examples.Tickets.TicketService.mk', [
    action(() => client.list()), input => action(() => client.save(input)),
  ]);
}
