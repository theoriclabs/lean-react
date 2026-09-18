/** Dev-only cleartext loopback proxy. Run:
 * LEANAPP_AUTH_API=http://127.0.0.1:<backendport> node scripts/auth-dev.mjs
 * PORT defaults to 4175. Configure that exact UI origin at the backend, with its
 * explicit development cookie mode. No CDN, dotenv loading, credential logging,
 * arbitrary upstream URL, or production hosting claim. --build-only builds assets.
 * Receipt/checks: node --test tests/integration/auth-client.test.mjs.
 * Client API: createAuthClient({fetch?}), signup/login/logout/restore,
 * getSnapshot/subscribe, protected request and Contract call. CSRF remains private;
 * neither browser storage nor diagnostics contain credentials.
 * Proxy body limit: 16 KiB; timeout: 30 seconds; upstream fixed to explicit loopback.
 * Assets are rebuilt at startup (restart after edits); no watch/HMR implementation.
 */
import { mkdir, copyFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { resolve } from 'node:path';
import { build } from 'esbuild';
import { createGateway } from '../engine/gateway/index.mjs';

const root = fileURLToPath(new URL('../', import.meta.url));
const port = Number(process.env.PORT ?? 4175);
const dist = resolve(root, 'examples/dist-auth');
await mkdir(dist, { recursive: true });
await build({ entryPoints: [resolve(root, 'examples/auth/main.mjs')], outfile: resolve(dist, 'main.js'),
  bundle: true, format: 'esm', platform: 'browser', loader: { '.mjs': 'jsx' }, logLevel: 'silent' });
await copyFile(resolve(root, 'examples/auth/index.html'), resolve(dist, 'index.html'));
await copyFile(resolve(root, 'examples/auth/style.css'), resolve(dist, 'style.css'));
if (!process.argv.includes('--build-only')) {
  await createGateway({ name: 'Auth UI (development only)', port, origin: `http://127.0.0.1:${port}`, development: true,
    backend: { attach: { url: process.env.LEANAPP_AUTH_API ?? 'invalid:' } },
    assets: { dir: dist, files: [['/', 'index.html', 'text/html'], ['/index.html', 'index.html', 'text/html'], ['/main.js', 'main.js', 'text/javascript'], ['/style.css', 'style.css', 'text/css']] },
    routes: { fromManifest: true, extra: ['/auth/*', '/api/*'], bodyBytes: { default: 16 * 1024 } },
    limits: { upstreamTimeoutMs: 30000 } });
}
