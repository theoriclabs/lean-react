// Presentation/HTTP process only. Authentication, authorization and persistence are owned by Lean.
import { mkdir } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';
import { createGateway } from '../engine/gateway/index.mjs';
const root = fileURLToPath(new URL('../', import.meta.url));
const development = process.env.LEANAPP_DEVELOPMENT === '1';
const port = Number(process.env.PORT ?? 4190), backendPort = Number(process.env.LEANAPP_BACKEND_PORT ?? 4191);
const origin = process.env.LEANAPP_ORIGIN ?? (development ? `http://127.0.0.1:${port}` :
  process.env.RAILWAY_PUBLIC_DOMAIN ? `https://${process.env.RAILWAY_PUBLIC_DOMAIN}` : '');
if (!origin) throw new Error('Set LEANAPP_ORIGIN to the public HTTPS origin.');
if (!development && !process.env.LEANAPP_DB_PATH && !process.env.RAILWAY_VOLUME_MOUNT_PATH)
  throw new Error('Persistent storage required: set LEANAPP_DB_PATH or attach a Railway volume.');
const db = process.env.LEANAPP_DB_PATH ?? (development ? resolve(root, '.lake/notes.sqlite') :
  resolve(process.env.RAILWAY_VOLUME_MOUNT_PATH, 'notes.sqlite'));
await mkdir(dirname(db), { recursive: true });
await createGateway({ name: 'Private Notes', port, origin, development,
  backend: { binary: process.env.LEANAPP_NOTES_BINARY ?? resolve(root, 'adapters/native/.lake/build/bin/leanapp_notes'),
    port: backendPort, env: { LEANAPP_DB_PATH: db } },
  assets: { dir: resolve(root, 'examples/dist-notes'), files: [['/', 'index.html', 'text/html'], ['/main.js', 'main.js', 'text/javascript'],
    ['/style.css', 'style.css', 'text/css'], ['/evidence.json', 'evidence.json', 'application/json'], ['/spec.lean', 'spec.lean', 'text/plain'], ['/model.lean', 'model.lean', 'text/plain']] },
  // Until the manifest carries http.path, extra mirrors the approved notes routes.
  routes: { fromManifest: true, extra: ['/auth/*', ...['list', 'lookup', 'search', 'count', 'export', 'lab'].map(name => `/api/notes/${name}`)] } });
