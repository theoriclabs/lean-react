// The Playwright web server: a disposable database on test ports.
import { mkdtemp } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { resolve } from 'node:path';
const fixture = await mkdtemp(resolve(tmpdir(), '{{name}}-browser-'));
process.env.LEANAPP_DEVELOPMENT = '1';
process.env.LEANAPP_DB_PATH = resolve(fixture, '{{name}}.sqlite');
process.env.PORT = '4272';
process.env.LEANAPP_BACKEND_PORT = '4273';
await import('../gateway/serve.mjs');
