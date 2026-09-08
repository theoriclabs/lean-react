// Explicitly opt-in public checks; disposable credentials stay in memory.
import assert from 'node:assert/strict';
import { randomUUID, createHash } from 'node:crypto';
import { once } from 'node:events';
import { readFile, mkdir, writeFile } from 'node:fs/promises';

const origin = new URL(process.argv[2]).origin;
if (!origin.startsWith('https://') || !process.argv.includes('--allow-mutations'))
  throw new Error('Usage: node scripts/check-notes-hosted.mjs HTTPS_ORIGIN --allow-mutations [--pause-for-restart]');
const criteria = { search: '', id: null, offset: '0', limit: '50' };
const get = path => fetch(origin + path, { signal: AbortSignal.timeout(15000) });
const post = async (path, body, session, extra = {}) => {
  const response = await fetch(origin + path, { method: 'POST', headers: {
    origin, 'content-type': 'application/json', 'x-leanapp-request': '1',
    ...(session ? { cookie: session.cookie, 'x-csrf-token': session.csrf } : {}), ...extra,
  }, body: JSON.stringify(body), signal: AbortSignal.timeout(15000) });
  return { status: response.status, body: await response.json(), cookie: response.headers.get('set-cookie') };
};
const call = (name, session, input = criteria, extra) => post(`/api/notes/${name}`, {
  operation: { namespace: 'notes', name, version: '1' }, kind: name === 'lab' ? 'command' : 'query',
  input: name === 'lab' ? null : input,
}, session, extra);
const signup = async () => {
  const username = `public_${randomUUID().slice(0, 12)}`, password = randomUUID() + randomUUID();
  const reply = await post('/auth/signup', { username, password }); assert.equal(reply.status, 200);
  assert.match(reply.cookie, /^__Host-leanapp_session=/);
  for (const flag of ['HttpOnly', 'Secure', 'SameSite=Strict', 'Path=/']) assert.ok(reply.cookie.includes(flag));
  assert.ok(!reply.cookie.includes('Domain=')); assert.ok(!('token' in reply.body));
  return { cookie: reply.cookie.split(';')[0], csrf: reply.body.csrf, username, password };
};
const ready = await get('/health/ready'); assert.equal(ready.status, 200);
assert.deepEqual(await ready.json(), { ready: true });
assert.equal(ready.headers.get('cache-control'), 'no-store');
assert.match(ready.headers.get('strict-transport-security'), /max-age=/);
const receipt = await (await get('/evidence.json')).json();
assert.equal(receipt.theoremCount, 9);
assert.equal(receipt.examples.filter(x => x.actual === 'rejected').length, 8);
assert.equal(receipt.examples.filter(x => x.actual === 'accepted').length, 1);
for (const [path, source] of [['/spec.lean', 'examples/security/PrivateNotes/Spec.lean'], ['/model.lean', 'examples/security/PrivateNotes/Model.lean']]) {
  const bytes = Buffer.from(await (await get(path)).arrayBuffer());
  assert.equal(createHash('sha256').update(bytes).digest('hex'), receipt.sources[source]);
  assert.deepEqual(bytes, await readFile(new URL('../' + source, import.meta.url)));
}
assert.equal((await call('list')).status, 401);
const alice = await signup();
const lab = await call('lab', alice); assert.equal(lab.status, 200);
const own = await call('list', alice); assert.equal(own.status, 200);
assert.equal(own.body.value.count, '2');
assert.deepEqual(own.body.value.notes.map(n => n.title), ['Launch budget', 'Garden notes']);
assert.equal((await call('list', alice, { ...criteria, tenant: 'forged' })).status, 400);
assert.equal((await call('list', alice, criteria, { 'x-csrf-token': '' })).status, 401);
assert.equal((await call('list', alice, criteria, { origin: 'https://foreign.example' })).status, 403);
const bob = await signup(); await call('lab', bob);
const other = await call('list', bob); assert.equal(other.status, 200);
assert.deepEqual((await call('list', alice)).body, own.body);
const missing = await call('lookup', alice, { ...criteria, id: '9223372036854775807' });
assert.equal(missing.status, 404);
for (const id of [lab.body.value.foreignId, lab.body.value.archiveId, other.body.value.notes[0].id]) {
  const foreign = await call('lookup', alice, { ...criteria, id });
  assert.equal(foreign.status, 404); assert.deepEqual(foreign.body, missing.body);
}
assert.equal((await call('search', alice, { ...criteria, search: 'budget' })).body.value.count, '1');
assert.equal((await call('count', alice, { ...criteria, search: 'budget' })).body.value.count, '1');
assert.equal((await call('search', alice, { ...criteria, search: "' OR 1=1 --" })).body.value.count, '0');
assert.deepEqual((await call('export', alice)).body.value, own.body.value);
assert.ok(!JSON.stringify(own.body).includes('CANARY'));
console.log('PASS: public HTTPS, source/evidence hash agreement, auth/cookie/origin/CSRF, owner/tenant isolation, foreign/missing equivalence, literal search/count/export.');
let restarted = false;
if (process.argv.includes('--pause-for-restart')) {
  console.log('READY_FOR_RESTART: restart only Private Notes, verify provider SUCCESS and readiness, then press Enter.');
  process.stdin.resume(); await once(process.stdin, 'data'); process.stdin.pause();
  assert.equal((await get('/health/ready')).status, 200);
  assert.deepEqual((await call('list', alice)).body, own.body);
  assert.deepEqual((await call('list', bob)).body, other.body);
  assert.deepEqual((await call('lab', alice)).body, lab.body);
  restarted = true;
  console.log('PASS: original cookies, private notes and fixture IDs survived the provider restart.');
}
const login = await post('/auth/login', { username: alice.username, password: alice.password });
assert.equal(login.status, 200); assert.equal((await call('list', alice)).status, 401);
const next = { cookie: login.cookie.split(';')[0], csrf: login.body.csrf };
assert.deepEqual((await call('list', next)).body, own.body);
assert.equal((await post('/auth/logout', {}, next)).status, 200);
assert.equal((await call('export', next)).status, 401);
assert.equal((await post('/auth/logout', {}, bob)).status, 200);
const dir = new URL('../.lake/security/', import.meta.url); await mkdir(dir, { recursive: true });
await writeFile(new URL('hosted-check.json', dir), JSON.stringify({ origin, checkedAt: new Date().toISOString(),
  result: 'passed', providerRestartVerified: restarted, theoremCount: receipt.theoremCount,
  rejectedCandidates: 8, buildEvidenceGeneratedAt: receipt.generatedAt, sources: receipt.sources,
  accounts: 'Two disposable synthetic accounts remain; both sessions logged out; no credentials recorded.' }, null, 2) + '\n');
console.log('PASS: session rotation and logout. Public-check receipt saved without credentials.');
