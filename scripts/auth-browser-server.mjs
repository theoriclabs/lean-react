import { spawn } from 'node:child_process';
import { mkdtemp } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { resolve } from 'node:path';

const fixture = await mkdtemp(resolve(tmpdir(), 'leanapp-auth-browser-'));
const backend = spawn(process.env.LEANAPP_AUTH_BINARY ?? resolve('adapters/native/.lake/build/bin/leanapp_auth_demo'),
  ['4178', resolve(fixture, 'auth.sqlite'), 'http://127.0.0.1:4177'], { stdio: 'inherit' });
let frontend, stopping = false;
function stop(code = 0) {
  if (stopping) return; stopping = true;
  for (const child of [frontend, backend]) if (child && child.exitCode === null) child.kill('SIGTERM');
  const timer = setTimeout(() => {
    for (const child of [frontend, backend]) if (child && child.exitCode === null && child.signalCode === null) child.kill('SIGKILL');
    process.exit(code);
  }, 1000);
  timer.unref();
}
process.on('SIGINT', () => stop()); process.on('SIGTERM', () => stop());
backend.on('error', () => stop(1));
backend.on('exit', code => { if (!stopping) stop(code || 1); });
try {
  let ready = false;
  for (let attempt = 0; attempt < 100; attempt++) {
    if (stopping) break;
    try { if ((await fetch('http://127.0.0.1:4178/health/ready')).ok) { ready = true; break; } } catch {}
    await new Promise(resolve => setTimeout(resolve, 50));
  }
  if (!ready) throw new Error('Auth backend failed readiness');
  frontend = spawn(process.execPath, ['scripts/auth-dev.mjs'], {
    env: { ...process.env, PORT: '4177', LEANAPP_AUTH_API: 'http://127.0.0.1:4178' }, stdio: 'inherit',
  });
  frontend.on('error', () => stop(1));
  frontend.on('exit', code => { if (!stopping) stop(code || 1); });
} catch { stop(1); }
