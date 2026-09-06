import test from 'node:test';
import assert from 'node:assert/strict';
import * as program from '../../examples/generated/tickets.mjs';
import { ctor } from '../../engine/adapters/leanjs-react.mjs';

const domain = name => program[`Examples.Tickets.${name}`];
const parse = domain('Title.parse');
const seed = domain('initialTickets');
const list = value => value.tag === 'List.nil' ? [] : [value.fields[0], ...list(value.fields[1])];

test('the compiled domain parser retains typed errors and Unicode scalar semantics', () => {
  assert.equal(parse('').fields[0].tag, 'Examples.Tickets.TitleError.empty');
  assert.equal(parse('😀'.repeat(200)).tag, 'Except.ok');
  const error = parse('😀'.repeat(201));
  assert.equal(error.tag, 'Except.error');
  assert.equal(error.fields[0].fields[0], 201n);
  assert.equal(domain('TitleError.message')(error.fields[0]), 'Keep the title under 201 characters (currently 201).');
});

test('compiled shared saves preserve exact revisions, old snapshots, and typed conflicts', () => {
  const [id, , value] = seed[0].fields;
  const revision = 2n ** 200n;
  const current = ctor('Examples.Tickets.TicketSummary.mk', [id, revision, value]);
  const title = parse('Shared logic').fields[0];
  const input = ctor('Examples.Tickets.SaveTicket.mk', [id, revision, title, value.fields[1]]);
  const saved = domain('applySave')(current, input);
  assert.equal(saved.tag, 'Except.ok');
  assert.equal(saved.fields[0].fields[1], revision + 1n);
  assert.equal(current.fields[1], revision);
  assert.equal(current.fields[2].fields[0].fields[0], 'Make components ordinary values');
  const stale = domain('applySave')(saved.fields[0], input);
  assert.equal(stale.tag, 'Except.error');
  assert.equal(stale.fields[0].tag, 'Examples.Tickets.SaveError.conflict');
  assert.equal(stale.fields[0].fields[0], saved.fields[0]);
});

test('a second consumer composes exported projections, callbacks, and query fragments', () => {
  assert.equal(domain('countOpen')(seed), 2n);
  assert.deepEqual(domain('renderTitles')(title => title.fields[0].toUpperCase(), seed),
    seed.map(ticket => ticket.fields[2].fields[0].fields[0].toUpperCase()));
  assert.deepEqual(list(domain('previewTitles')(1n, seed)), ['Make components ordinary values']);
  assert.equal(list(domain('previewTitles')(100n, seed)).length, 2);
});
