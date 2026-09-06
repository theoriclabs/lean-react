// Explicit public-wire / LeanJS representation adapter. Domain validation stays in Lean.
import * as domain from '../generated/domain.mjs';

const ctor = (tag, fields = []) => ({ tag, fields });
const ok = value => ctor('Except.ok', [value]);
const err = value => ctor('Except.error', [value]);
const identity = name => ({ namespace: 'leanreact.tickets', name, version: '1' });

export class CallFailure extends Error {
  constructor(kind, code, detail = null) {
    super(code); this.name = 'CallFailure'; this.kind = kind; this.code = code; this.detail = detail;
  }
}
function fail(code, value) { throw new CallFailure('decode', code, value); }
function object(value, keys) {
  if (!value || typeof value !== 'object' || Array.isArray(value) ||
      Object.keys(value).length !== keys.length || keys.some(key => !Object.hasOwn(value, key))) fail('decode.object', value);
  return value;
}
function string(value) { if (typeof value !== 'string') fail('decode.string', value); return value; }
function equalIdentity(left, right) {
  object(left, ['namespace', 'name', 'version']);
  return left.namespace === right.namespace && left.name === right.name && left.version === right.version;
}
export function encodeNat(value) {
  if (typeof value !== 'bigint' || value < 0n) fail('encode.nat', value);
  return { tag: 'nat', value: value.toString() };
}
export function decodeNat(value) {
  object(value, ['tag', 'value']);
  if (value.tag !== 'nat' || typeof value.value !== 'string' || !/^(0|[1-9][0-9]*)$/.test(value.value)) fail('decode.nat', value);
  return BigInt(value.value);
}
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

// Decode non-2xx bodies too: domain failures carry useful typed payloads.
export function decodeReply(name, status, body) {
  const expected = identity(name);
  if (body?.tag === 'success' || body?.tag === 'domainError') {
    object(body, ['operation', 'tag', 'value']);
    if (!equalIdentity(body.operation, expected)) throw new CallFailure('protocol', 'response.operation_mismatch', body);
    if (body.tag === 'success') {
      if (status !== 200) throw new CallFailure('protocol', 'response.status_mismatch', body);
      if (name === 'list') {
        if (!Array.isArray(body.value)) fail('decode.array', body.value);
        return ok(body.value.map(decodeSummary));
      }
      return ok(decodeSummary(body.value));
    }
    if (name !== 'save') throw new CallFailure('protocol', 'response.unexpected_domain_error', body);
    object(body.value, ['tag', 'value']);
    if (body.value.tag === 'notFound' && body.value.value === null && status === 404)
      return err(ctor('Examples.Tickets.SaveError.notFound'));
    if (body.value.tag === 'conflict' && status === 409)
      return err(ctor('Examples.Tickets.SaveError.conflict', [decodeSummary(body.value.value)]));
    throw new CallFailure('protocol', 'response.invalid_domain_error', body);
  }
  if (body?.tag === 'incompatible' && status === 409) {
    object(body, ['tag', 'expected', 'received']);
    if (!equalIdentity(body.received, expected)) throw new CallFailure('protocol', 'response.operation_mismatch', body);
    object(body.expected, ['namespace', 'name', 'version']);
    throw new CallFailure('incompatible', 'contract.incompatible', body);
  }
  if (body?.tag === 'decode' && status === 400) throw new CallFailure('decode', 'server.decode', body.errors);
  if (body?.tag === 'protocol' && status >= 400) throw new CallFailure('protocol', string(body.code), body);
  throw new CallFailure('protocol', 'response.unknown_envelope', body);
}

export function createTicketsClient({ baseURL = '', fetch: fetchImpl = globalThis.fetch } = {}) {
  async function call(name, input, signal) {
    const request = { operation: identity(name), kind: name === 'list' ? 'query' : 'command', input };
    let response;
    try {
      response = await fetchImpl(`${baseURL}/api/tickets/${name}`, {
        method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(request), signal,
      });
    } catch (cause) {
      throw new CallFailure(signal?.aborted ? 'cancelled' : 'transport', signal?.aborted ? 'request.cancelled' : 'request.failed', cause);
    }
    let body;
    try { body = await response.json(); } catch (cause) { throw new CallFailure('decode', 'response.invalid_json', cause); }
    return decodeReply(name, response.status, body);
  }
  return {
    async list({ signal } = {}) { return (await call('list', null, signal)).fields[0]; },
    save(input, { signal } = {}) { return call('save', encodeSave(input), signal); },
  };
}
