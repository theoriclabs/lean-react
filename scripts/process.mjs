import { spawn } from 'node:child_process';

/** Run and collect combined stdout/stderr; resolves with the exit code instead of rejecting on failure. */
export function capture(command, args = [], options = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { stdio: ['ignore', 'pipe', 'pipe'], ...options });
    let output = '';
    child.stdout.on('data', chunk => { output += chunk; });
    child.stderr.on('data', chunk => { output += chunk; });
    child.once('error', reject);
    child.once('exit', (code, signal) => resolve({ code: code ?? signal, output }));
  });
}

export function run(command, args = [], options = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { stdio: 'inherit', ...options });
    child.once('error', reject);
    child.once('exit', (code, signal) => {
      if (code === 0) resolve();
      else reject(new Error(`${command} ${args.join(' ')} failed (${signal ?? code})`));
    });
  });
}
