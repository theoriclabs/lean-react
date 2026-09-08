import { mkdtemp } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { resolve } from 'node:path';
const fixture = await mkdtemp(resolve(tmpdir(), 'leanapp-cafe-browser-'));
process.env.LEANAPP_DEVELOPMENT = '1';
process.env.LEANAPP_DB_PATH = resolve(fixture, 'cafe.sqlite');
process.env.PORT = '4182'; process.env.LEANAPP_BACKEND_PORT = '4183';
await import('./serve-cafe.mjs');
