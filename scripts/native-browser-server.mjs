import { spawn } from 'node:child_process';
import { mkdtemp } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createInterface } from 'node:readline';

const directory = await mkdtemp(join(tmpdir(), 'leanreact-browser-'));
const backend = spawn('examples/native/.lake/cached/bin/tickets_server', ['0', join(directory, 'tickets.sqlite')],
  { stdio: ['ignore', 'ignore', 'pipe'] });
const stop = () => { if (backend.exitCode === null) backend.kill('SIGTERM'); };
process.on('exit', stop);
for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => { stop(); process.exit(0); });

const port = await new Promise((resolve, reject) => {
  const timer = setTimeout(() => { stop(); reject(new Error('Native fixture startup timed out')); }, 15_000);
  backend.once('error', error => { clearTimeout(timer); reject(error); });
  backend.once('exit', code => { clearTimeout(timer); reject(new Error(`Native fixture exited: ${code}`)); });
  createInterface({ input: backend.stderr }).on('line', line => {
    try {
      const event = JSON.parse(line);
      if (event.event === 'tickets.ready') { clearTimeout(timer); resolve(event.port); }
    } catch { console.error(line); }
  });
});
process.env.LEANREACT_API = `http://127.0.0.1:${port}`;
process.argv.push('--no-build');
console.log(`Native browser fixture retained at ${directory}`);
await import('./dev.mjs');
