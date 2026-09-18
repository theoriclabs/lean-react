import * as React from 'react';
import { asReactComponent } from '../../engine/adapters/leanjs-react.mjs';
import * as components from '../generated/smoke.mjs';
import * as domain from '../generated/domain.mjs';
import { __leanjs as providerManifest, type LeanLibraryInterface } from '../generated/provider.mjs';
import { createClient, operations, type SaveInput, type SaveOutput } from '../adapters/tickets-client/operations.mjs';

const makeCounterProps = components['Examples.Tickets.CounterProps.mk'];
const Counter = asReactComponent(components['Examples.Tickets.Counter'],
  (props: { label: Parameters<typeof makeCounterProps>[0]; initial: Parameters<typeof makeCounterProps>[1] }) =>
    makeCounterProps(props.label, props.initial));

export const example = <Counter label="From TypeScript" initial={9007199254740993n} />;
export const validTitle = domain['Examples.Tickets.Title.parse']('Shared domain validation');
export const linkedLibraries: readonly LeanLibraryInterface[] = providerManifest.imports;
export const initializedValues: readonly string[] = providerManifest.initialized;

// The generated wire client: identities select typed call overloads, errors are tagged unions.
const client = createClient({ baseURL: 'http://127.0.0.1:4173', verify: true });
export const draft: SaveInput = {
  id: { type: { package: 'leanreact.tickets', name: 'Ticket' }, scope: 'tickets-demo', key: '1' },
  expectedRevision: 1n, title: 'Typed through the manifest', status: 'inProgress',
};
export async function saveOrCurrent(input: SaveInput): Promise<SaveOutput | null> {
  const result = await client.call(operations.save.identity, input);
  if (result.ok) return result.value;
  return result.error.tag === 'conflict' ? result.error.value : null;
}
export const openRevisions: Promise<bigint[]> = client.call(operations.list.identity, null)
  .then(result => result.ok ? result.value.filter(ticket => ticket.value.assignee.tag === 'some').map(ticket => ticket.revision) : []);
export const savePath: string = operations.save.path;

// These expectations prevent the interop boundary from silently degrading to any.
// @ts-expect-error Lean Nat uses bigint, including values that happen to be small.
const wrongNumber = <Counter label="Wrong" initial={1} />;
// @ts-expect-error Shared parser accepts a string.
domain['Examples.Tickets.Title.parse'](123);
// @ts-expect-error Wire naturals are bigint in generated inputs too.
void client.call(operations.save.identity, { ...draft, expectedRevision: 1 });
// @ts-expect-error The list query takes null, not an object.
void client.call(operations.list.identity, {});
void wrongNumber;
