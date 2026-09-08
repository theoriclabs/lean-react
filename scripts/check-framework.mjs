import { run } from './process.mjs';
import { projectRoot } from './build.mjs';
import { resolve } from 'node:path';
import { mkdtemp } from 'node:fs/promises';
import { tmpdir } from 'node:os';

const profile = process.argv[2] ?? 'portable';
const cwd = projectRoot;

const nativeOverrides = () => ['leanreact', 'leandb', 'leanhttp', 'leansqlite', 'openssl'].flatMap(name => {
  const source = process.env[`LEANAPP_${name.toUpperCase()}_SOURCE`];
  return source ? [`-K${name}=${resolve(source)}`] : [];
});

if (profile === 'portable') {
  await run('lake', ['build', 'LeanApp', 'Ordering'], { cwd });
  await run('lake', ['env', 'lean', '--run', 'tests/framework/Import.lean'], { cwd });
  await run('node', ['scripts/test.mjs'], { cwd });
  await run('bash', ['tests/app/check.sh'], { cwd });
  await run('bash', ['tests/ordering/check.sh'], { cwd });
} else if (profile === 'native') {
  const native = resolve(cwd, 'adapters/native');
  const overrides = nativeOverrides();
  await run('lake', [...overrides, '--no-cache', 'build', 'leanapp_storage_checks'], { cwd: native });
  await run(resolve(native, '.lake/build/bin/leanapp_storage_checks'), [], { cwd: native });
  await run('lake', [...overrides, '--no-cache', 'build', 'LeanAppNative'], { cwd: native });
  await run('lake', ['env', 'lean', '--run', 'HttpChecks.lean'], { cwd: native });
  await run('lake', [...overrides, '--no-cache', 'build', 'leanapp_managed_checks'], { cwd: native });
  const fixture = await mkdtemp(resolve(tmpdir(), 'leanapp-managed-'));
  console.log(`Managed dispatch fixture: ${fixture}`);
  await run(resolve(native, '.lake/build/bin/leanapp_managed_checks'), [fixture], { cwd: native });
} else if (profile === 'auth') {
  const native = resolve(cwd, 'adapters/native');
  await run('lake', [...nativeOverrides(), '--no-cache', 'build', 'leanapp_crypto_checks', 'leanapp_auth_checks', 'leanapp_auth_demo'], { cwd: native });
  for (const binary of ['leanapp_crypto_checks', 'leanapp_auth_checks'])
    await run(resolve(native, '.lake/build/bin', binary), [], { cwd: native });
  await run('node', ['--test', 'tests/auth/http.test.mjs'], { cwd });
  await run('node', ['--test', 'tests/integration/auth-client.test.mjs'], { cwd });
} else if (profile === 'browser') {
  await run('npm', ['run', 'test:browser'], { cwd });
  await run('npm', ['run', 'test:native:browser'], { cwd });
} else {
  throw new Error(`Unknown framework check profile: ${profile}; use portable, native, auth, or browser`);
}
