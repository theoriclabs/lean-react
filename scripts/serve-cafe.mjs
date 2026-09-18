// Presentation/HTTP process only. Credentials, prices and persistence are owned by Lean.
import { mkdir } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';
import { createGateway } from '../engine/gateway/index.mjs';
const root = fileURLToPath(new URL('../', import.meta.url));
const development = process.env.LEANAPP_DEVELOPMENT === '1';
const port = Number(process.env.PORT ?? 4180), backendPort = Number(process.env.LEANAPP_BACKEND_PORT ?? 4181);
const origin = process.env.LEANAPP_ORIGIN ?? (development ? `http://127.0.0.1:${port}` :
  process.env.RAILWAY_PUBLIC_DOMAIN ? `https://${process.env.RAILWAY_PUBLIC_DOMAIN}` : '');
if (!origin) throw new Error('Set LEANAPP_ORIGIN to the public HTTPS origin.');
if (!development && !process.env.LEANAPP_DB_PATH && !process.env.RAILWAY_VOLUME_MOUNT_PATH)
  throw new Error('Persistent storage required: set LEANAPP_DB_PATH or attach a Railway volume.');
const db = process.env.LEANAPP_DB_PATH ?? (development ? resolve(root, '.lake/cafe.sqlite') :
  resolve(process.env.RAILWAY_VOLUME_MOUNT_PATH, 'cafe.sqlite'));
await mkdir(dirname(db), { recursive: true });
await createGateway({ name: 'Proof & Pour', port, origin, development,
  backend: { binary: process.env.LEANAPP_CAFE_BINARY ?? resolve(root, 'adapters/native/.lake/build/bin/leanapp_cafe'),
    port: backendPort, env: { LEANAPP_DB_PATH: db } },
  assets: { dir: resolve(root, 'examples/dist-cafe') },
  // Until the manifest carries http.path, extra mirrors the approved café routes.
  routes: { fromManifest: true, extra: ['/auth/*', '/api/recipes/list', '/api/recipes/save', '/api/recipes/delete'] } });
