// Explicit public-wire / LeanJS representation adapter. Domain validation stays in Lean.
import * as domain from '../generated/domain.mjs';
import { CallFailure, wireObject as object, encodeNat, decodeNat, defineHttpOperation, decodeHttpReply, createHttpClient } from '../../engine/LeanContract/Fetch.mjs';
export { CallFailure, encodeNat, decodeNat };

const ctor = (tag, fields = []) => ({ tag, fields });
const ok = value => ctor('Except.ok', [value]);
const err = value => ctor('Except.error', [value]);
const identity = name => ({ namespace: 'leanreact.tickets', name, version: '1' });

function fail(code, value) { throw new CallFailure('decode', code, value); }
function string(value) { if (typeof value !== 'string') fail('decode.string', value); return value; }
export function encodeId(value, name = 'Ticket') {
  return { type: { package: 'leanreact.tickets', name }, scope: value.fields[0].fields[0], key: value.fields[1] };
}
export function decodeId(value, name = 'Ticket') {
  object(value, ['type', 'scope', 'key']); object(value.type, ['package', 'name']);
  if (value.type.package !== 'leanreact.tickets' || value.type.name !== name) fail('identity.type_mismatch', value);
  const parsed = domain['Ontology.EntityId.parse'](null, string(value.scope), string(value.key));
  if (parsed.tag !== 'Except.ok') fail('identity.invalid', value);
  return parsed.fields[0];
}
function decodeTitle(value) {
  const result = domain['Examples.Tickets.Title.parse'](string(value));
  if (result.tag !== 'Except.ok') fail('title.invalid', value);
  return result.fields[0];
}
function decodeStatus(value) {
  const result = domain['Examples.Tickets.Status.parse'](string(value));
  if (result.tag !== 'Option.some') fail('status.unknown', value);
  return result.fields[0];
}
function encodeStatus(value) {
  const names = { 'Examples.Tickets.Status.backlog': 'backlog', 'Examples.Tickets.Status.inProgress': 'inProgress', 'Examples.Tickets.Status.done': 'done' };
  if (!Object.hasOwn(names, value.tag)) fail('encode.status', value);
  return names[value.tag];
}
function decodeAssignee(value) {
  if (value?.tag === 'none') { object(value, ['tag']); return ctor('Option.none'); }
  object(value, ['tag', 'value']);
  if (value.tag !== 'some') fail('decode.option', value);
  return ctor('Option.some', [decodeId(value.value, 'User')]);
}
function encodeAssignee(value) {
  return value.tag === 'Option.none' ? { tag: 'none' } : { tag: 'some', value: encodeId(value.fields[0], 'User') };
}
export function decodeSummary(value) {
  object(value, ['id', 'revision', 'value']); object(value.value, ['title', 'status', 'assignee']);
  return ctor('Examples.Tickets.TicketSummary.mk', [decodeId(value.id), decodeNat(value.revision),
    ctor('Examples.Tickets.Ticket.mk', [decodeTitle(value.value.title), decodeStatus(value.value.status), decodeAssignee(value.value.assignee)])]);
}
export function encodeSummary(value) {
  const [id, revision, ticket] = value.fields;
  return { id: encodeId(id), revision: encodeNat(revision), value: {
    title: ticket.fields[0].fields[0], status: encodeStatus(ticket.fields[1]), assignee: encodeAssignee(ticket.fields[2]),
  } };
}
export function encodeSave(value) {
  const [id, expectedRevision, title, status] = value.fields;
  return { id: encodeId(id), expectedRevision: encodeNat(expectedRevision), title: title.fields[0], status: encodeStatus(status) };
}

const listOperation = defineHttpOperation({
  identity: identity("list"), kind: "query", path: "/api/tickets/list", encodeInput: () => null,
  decodeOutput(value) {
    if (!Array.isArray(value)) fail("decode.array", value);
    return value.map(decodeSummary);
  },
});
const saveOperation = defineHttpOperation({
  identity: identity("save"), kind: "command", path: "/api/tickets/save", encodeInput: encodeSave,
  decodeOutput: decodeSummary,
  decodeError(value) {
    object(value, ["tag", "value"]);
    if (value.tag === "notFound" && value.value === null) return ctor("Examples.Tickets.SaveError.notFound");
    if (value.tag === "conflict") return ctor("Examples.Tickets.SaveError.conflict", [decodeSummary(value.value)]);
    throw new CallFailure("protocol", "response.invalid_domain_error", value);
  },
  errorStatus: error => error.tag === "Examples.Tickets.SaveError.notFound" ? 404 : 409,
});
const operations = [listOperation, saveOperation];
const leanResult = result => result.ok ? ok(result.value) : err(result.error);

export function decodeReply(name, status, body) {
  const operation = operations.find(op => op.identity.name === name);
  if (!operation) throw new CallFailure("protocol", "operation.not_found");
  return leanResult(decodeHttpReply(operation, status, body));
}

export function createTicketsClient(options = {}) {
  const client = createHttpClient({ ...options, operations });
  return {
    async list(options) { return (await client.call(listOperation.identity, null, options)).value; },
    async save(input, options) { return leanResult(await client.call(saveOperation.identity, input, options)); },
    // The raw client and identities let a cancellable resource loader forward its AbortSignal.
    http: client,
    identities: { list: listOperation.identity, save: saveOperation.identity },
  };
}
