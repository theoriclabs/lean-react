// The public process: static assets, origin/body/admission limits and a proxy to the Lean
// listener on loopback. Everything else (credentials, rules, persistence) is owned by Lean.
import { mkdir } from 'node:fs/promises';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { dirname, resolve } from 'node:path';

const root = fileURLToPath(new URL('../', import.meta.url));
const engine = process.env.LEANAPP_LEANREACT_SOURCE
  ? resolve(process.env.LEANAPP_LEANREACT_SOURCE, 'engine')
  : resolve(root, '.lake/packages/leanreact/engine');
const { createGateway } = await import(pathToFileURL(resolve(engine, 'gateway/index.mjs')).href);

const development = process.env.LEANAPP_DEVELOPMENT === '1';
const port = Number(process.env.PORT ?? 4270);
const backendPort = Number(process.env.LEANAPP_BACKEND_PORT ?? 4271);
const origin = process.env.LEANAPP_ORIGIN ?? (development ? `http://127.0.0.1:${port}` :
  process.env.RAILWAY_PUBLIC_DOMAIN ? `https://${process.env.RAILWAY_PUBLIC_DOMAIN}` : '');
if (!origin) throw new Error('Set LEANAPP_ORIGIN to the public HTTPS origin.');
const db = process.env.LEANAPP_DB_PATH ?? (development ? resolve(root, '.lake/{{name}}.sqlite') :
  process.env.RAILWAY_VOLUME_MOUNT_PATH ? resolve(process.env.RAILWAY_VOLUME_MOUNT_PATH, '{{name}}.sqlite') : '');
if (!db) throw new Error('Persistent storage required: set LEANAPP_DB_PATH or attach a Railway volume.');
await mkdir(dirname(db), { recursive: true });

await createGateway({
  name: '{{Name}}', port, origin, development,
  backend: {
    binary: process.env.LEANAPP_BINARY ?? resolve(root, 'native/.lake/build/bin/{{name}}_server'),
    port: backendPort, env: { LEANAPP_DB_PATH: db },
  },
  assets: { dir: resolve(root, 'dist') },
  routes: { fromManifest: true, extra: ['/auth/*'] },
});
