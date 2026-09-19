import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { resolve } from 'node:path';

export const root = fileURLToPath(new URL('../', import.meta.url));

/** A lean-react checkout instead of the pinned clone (`LEANAPP_LEANREACT_SOURCE`), or null. */
export const leanreact = process.env.LEANAPP_LEANREACT_SOURCE ? resolve(process.env.LEANAPP_LEANREACT_SOURCE) : null;

/** Where the JavaScript engine (runtime, adapters, gateway) is read from. */
export const engine = resolve(leanreact ?? resolve(root, '.lake/packages/leanreact'), 'engine');

/** Lake `-K` overrides from the environment, mirroring the lakefiles' `get_config?` keys. */
export function lakeOverrides() {
  const sources = [
    ['leanreact', leanreact],
    ['leanapp_native', leanreact ? resolve(leanreact, 'adapters/native') : null],
    ['leandb', process.env.LEANAPP_LEANDB_SOURCE],
    ['leanhttp', process.env.LEANAPP_LEANHTTP_SOURCE],
    ['leanws', process.env.LEANAPP_LEANWS_SOURCE],
    ['leansqlite', process.env.LEANAPP_LEANSQLITE_SOURCE],
    ['openssl', process.env.LEANAPP_OPENSSL_PREFIX],
  ];
  return sources.filter(([, value]) => value).map(([key, value]) => `-K${key}=${resolve(value)}`);
}

export function run(command, args, options = {}) {
  return new Promise((resolvePromise, reject) => {
    const child = spawn(command, args, { stdio: 'inherit', ...options });
    child.on('error', reject);
    child.on('exit', (code, signal) => {
      if (code === 0) resolvePromise();
      else reject(new Error(`${command} ${args.join(' ')} failed (${signal ?? code})`));
    });
  });
}
