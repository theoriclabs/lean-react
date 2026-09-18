// LeanJS representation bridge over the generated wire client. The generated codecs check wire
// shapes; the compiled Lean parsers below are the domain validation, and Lean constructors are
// the ABI the compiled components consume. See engine/LeanJS/ABI.md for the representations.
import { action, mapAction } from '../../engine/runtime/actions.mjs';
import { ctor } from '../../engine/adapters/leanjs-react.mjs';
import { resourceLoader } from '../../engine/LeanContract/Service.mjs';
import * as domain from '../generated/domain.mjs';
import { CallFailure, createClient, operations } from './tickets-client/operations.mjs';

const fail = (code, value) => { throw new CallFailure('decode', code, value); };
const ok = value => ctor('Except.ok', [value]);
const err = value => ctor('Except.error', [value]);
const statusNames = { 'Examples.Tickets.Status.backlog': 'backlog', 'Examples.Tickets.Status.inProgress': 'inProgress', 'Examples.Tickets.Status.done': 'done' };

export function idToLean(value) {
  const parsed = domain['Ontology.EntityId.parse'](null, value.scope, value.key);
  if (parsed.tag !== 'Except.ok') fail('identity.invalid', value);
  return parsed.fields[0];
}
export const idFromLean = (value, name = 'Ticket') =>
  ({ type: { package: 'leanreact.tickets', name }, scope: value.fields[0].fields[0], key: value.fields[1] });

export function titleToLean(value) {
  const result = domain['Examples.Tickets.Title.parse'](value);
  if (result.tag !== 'Except.ok') fail('title.invalid', value);
  return result.fields[0];
}
export function statusToLean(value) {
  const result = domain['Examples.Tickets.Status.parse'](value);
  if (result.tag !== 'Option.some') fail('status.unknown', value);
  return result.fields[0];
}
export function statusFromLean(value) {
  if (!Object.hasOwn(statusNames, value.tag)) fail('encode.status', value);
  return statusNames[value.tag];
}

export function summaryToLean(summary) {
  const assignee = summary.value.assignee.tag === 'none' ? ctor('Option.none')
    : ctor('Option.some', [idToLean(summary.value.assignee.value)]);
  return ctor('Examples.Tickets.TicketSummary.mk', [idToLean(summary.id), summary.revision,
    ctor('Examples.Tickets.Ticket.mk', [titleToLean(summary.value.title), statusToLean(summary.value.status), assignee])]);
}
export function summaryFromLean(value) {
  const [id, revision, ticket] = value.fields;
  const [title, status, assignee] = ticket.fields;
  return { id: idFromLean(id), revision, value: {
    title: title.fields[0], status: statusFromLean(status),
    assignee: assignee.tag === 'Option.none' ? { tag: 'none' } : { tag: 'some', value: idFromLean(assignee.fields[0], 'User') },
  } };
}
/** Wire encoding of a Lean `TicketSummary` for fixtures and fetch doubles. */
export const encodeSummary = summaryFromLean;

export function saveFromLean(value) {
  const [id, expectedRevision, title, status] = value.fields;
  return { id: idFromLean(id), expectedRevision, title: title.fields[0], status: statusFromLean(status) };
}
export const saveErrorToLean = error => error.tag === 'notFound'
  ? ctor('Examples.Tickets.SaveError.notFound') : ctor('Examples.Tickets.SaveError.conflict', [summaryToLean(error.value)]);
const leanResult = (result, decode) => result.ok ? ok(decode(result.value)) : err(saveErrorToLean(result.error));

export function createTicketsClient(options = {}) {
  const client = createClient(options);
  return {
    http: client,
    identities: { list: operations.list.identity, save: operations.save.identity },
    async list(callOptions) { return (await client.call(operations.list.identity, null, callOptions)).value.map(summaryToLean); },
    async save(input, callOptions) {
      return leanResult(await client.call(operations.save.identity, saveFromLean(input), callOptions), summaryToLean);
    },
  };
}

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
  return request => mapAction(result => result.value.map(summaryToLean), list(request, null));
}
