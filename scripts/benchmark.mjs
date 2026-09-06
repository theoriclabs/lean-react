import { performance } from 'node:perf_hooks';
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { gzipSync } from 'node:zlib';
import * as React from 'react';
import { renderToString } from 'react-dom/server';
import * as program from '../examples/generated/smoke.mjs';
import { mountElement } from '../engine/adapters/leanjs-react.mjs';

const names = Array.from({ length: 1_000 }, (_, i) => `Item ${i}`);
const component = program['Examples.Composition.Counters'];
const elapsed = [];
let html;
for (let trial = 0; trial < 6; trial++) {
  const start = performance.now();
  html = renderToString(mountElement(component, names));
  if (trial) elapsed.push(performance.now() - start);
}
elapsed.sort((a, b) => a - b);
const files = {};
for (const filename of ['examples/generated/domain.mjs', 'examples/generated/tickets.mjs', 'examples/dist/app.js']) {
  const source = await readFile(filename);
  files[filename] = { bytes: source.length, gzipBytes: gzipSync(source).length };
}
const measurement = {
  node: process.version, platform: `${process.platform}/${process.arch}`,
  react: React.version, mode: process.env.NODE_ENV ?? 'development',
  workload: 'React renderToString of 1,000 compiled Lean stateful counters; five warm samples',
  medianMilliseconds: Math.round(elapsed[2] * 100) / 100,
  minMilliseconds: Math.round(elapsed[0] * 100) / 100,
  maxMilliseconds: Math.round(elapsed[4] * 100) / 100,
  htmlBytes: Buffer.byteLength(html), files,
};
await mkdir('examples/generated', { recursive: true });
await writeFile('examples/generated/benchmark.json', JSON.stringify(measurement, null, 2) + '\n');
console.log(JSON.stringify(measurement, null, 2));
