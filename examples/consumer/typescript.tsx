import * as React from 'react';
import { asReactComponent } from '../../engine/adapters/leanjs-react.mjs';
import * as components from '../generated/smoke.mjs';
import * as domain from '../generated/domain.mjs';

const makeCounterProps = components['Examples.Tickets.CounterProps.mk'];
const Counter = asReactComponent(components['Examples.Tickets.Counter'],
  (props: { label: Parameters<typeof makeCounterProps>[0]; initial: Parameters<typeof makeCounterProps>[1] }) =>
    makeCounterProps(props.label, props.initial));

export const example = <Counter label="From TypeScript" initial={9007199254740993n} />;
export const validTitle = domain['Examples.Tickets.Title.parse']('Shared domain validation');

// These expectations prevent the interop boundary from silently degrading to any.
// @ts-expect-error Lean Nat uses bigint, including values that happen to be small.
const wrongNumber = <Counter label="Wrong" initial={1} />;
// @ts-expect-error Shared parser accepts a string.
domain['Examples.Tickets.Title.parse'](123);
void wrongNumber;
