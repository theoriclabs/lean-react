import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { transform } from 'esbuild';
const manifest = JSON.parse(readFileSync(new URL('./integration/examples/generated/tickets.manifest.json', import.meta.url), 'utf8'));

test('current Tickets bridge has statically expanded component hook plans', () => {
  const sites = name => manifest.hookPlans.find(p => p.name === `Examples.Tickets.${name}`)?.sites;
  assert.deepEqual(sites('Counter').map(s => s.site), ['count']);
  assert.deepEqual(sites('Editor').map(s => s.site), ['draft-title','save-notice']);
  assert.deepEqual(sites('PageEditor'), sites('Editor'));
  assert.deepEqual(sites('App').map(s => s.site), ['local-store']);
  assert.deepEqual(sites('Workspace'), []);
  assert.ok(sites('WorkspaceBody').length >= 5);
  assert.ok(sites('WorkspaceBody').some(s => s.kind === 'resource' && s.site === 'tickets-query'));
  assert.ok(sites('WorkspaceBody').some(s => s.kind === 'effect' && s.site === 'tickets-snapshot'));
  assert.deepEqual(sites('Card'), []);
});

test('Tickets declarations describe tagged ABI and opaque host results', async () => {
  const source = readFileSync(new URL('./integration/examples/generated/tickets.d.ts', import.meta.url), 'utf8');
  await transform(source, {loader:'ts',format:'esm'});
  assert.match(source,/LeanCtor<"LeanReact.Component.mk"/);
  assert.match(source,/LeanCtor<"Examples.Tickets.CounterProps.mk", readonly \[string, bigint\]>/);
  assert.match(source,/=> unknown/);
  assert.doesNotMatch(source,/React\.(FC|ComponentType|ReactNode)/);
});
