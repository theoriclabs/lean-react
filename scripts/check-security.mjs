// Trusted local qualification harness. Never executed on browser-supplied code.
import assert from 'node:assert/strict';
import { readFile, writeFile, mkdir, mkdtemp } from 'node:fs/promises';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
import { spawn } from 'node:child_process';
const root = fileURLToPath(new URL('../', import.meta.url));
const hash = s => createHash('sha256').update(s).digest('hex');
async function run(args) {
  return new Promise((accept, reject) => {
    const child = spawn('lake', args, { cwd: root, stdio: ['ignore', 'pipe', 'pipe'] });
    let output = '';
    for (const stream of [child.stdout, child.stderr]) stream.on('data', b => { output += b; });
    const timer = setTimeout(() => { child.kill('SIGTERM'); reject(new Error('Security check timed out')); }, 120000);
    child.on('error', e => { clearTimeout(timer); reject(e); });
    child.on('exit', code => { clearTimeout(timer); accept({ code, output }); });
  });
}
const build = await run(['build', 'PrivateNotes']);
assert.equal(build.code, 0, build.output);
const checks = await run(['env', 'lean', '--run', 'tests/security/Checks.lean']);
assert.equal(checks.code, 0, checks.output);
assert.doesNotMatch(checks.output, /sorryAx|sorry|Lean\.trustCompiler|ofReduceBool|implemented_by/);
const reports = [...checks.output.matchAll(/depends on axioms:\s*\[([^\]]*)\]/g)];
for (const [, axioms] of reports) for (const axiom of axioms.split(',').map(s => s.trim()).filter(Boolean))
  assert.ok(['propext', 'Quot.sound', 'Classical.choice'].includes(axiom), `Unexpected axiom: ${axiom}`);
assert.equal((checks.output.match(/depends on axioms:|does not depend on any axioms/g) ?? []).length, 9);
console.log(checks.output.trim());
await mkdir(resolve(root, '.lake/security'), { recursive: true });
const out = await mkdtemp(resolve(root, '.lake/security/run-'));
const modelPath = 'examples/security/PrivateNotes/Model.lean';
const specPath = 'examples/security/PrivateNotes/Spec.lean';
const model = await readFile(resolve(root, modelPath), 'utf8');
const spec = await readFile(resolve(root, specPath), 'utf8');
const examples = [{ id: 'valid', title: 'Keep the ownership contract', stage: 'Lean + axiom audit',
  expected: 'accepted', actual: 'accepted', code: 'owner == caller.actor && tenant == caller.tenant',
  diagnostic: checks.output.trim() }];
for (const [name, expected] of [['MissingGrant', 'Application type mismatch'], ['WrongCaller', 'Type mismatch'],
  ['WrongScope', 'Type mismatch'], ['ForgeGrant', 'Unknown constant']]) {
  const result = await run(['env', 'lean', `tests/security/${name}.lean`]);
  assert.notEqual(result.code, 0, `${name} unexpectedly compiled`);
  assert.ok(result.output.toLowerCase().includes(expected.toLowerCase()), result.output);
  await writeFile(resolve(out, `${name}.log`), result.output);
  examples.push({ id: name, title: name.replace(/([a-z])([A-Z])/g, '$1 $2'), stage: 'Lean type checker',
    expected: 'rejected', actual: 'rejected', code: await readFile(resolve(root, `tests/security/${name}.lean`), 'utf8'),
    diagnostic: result.output.trim() });
  console.log(`PASS: rejected ${name}`);
}
for (const [id, title, replacement] of [
  ['drop-owner', 'An agent removes the owner check', 'n.tenant == p.tenant'],
  ['drop-tenant', 'An agent removes the tenant check', 'n.owner == p.actor'],
]) {
  const candidate = model.replace('n.owner == p.actor && n.tenant == p.tenant', replacement);
  assert.notEqual(candidate, model);
  const file = resolve(out, `${id}.lean`); await writeFile(file, candidate);
  const result = await run(['env', 'lean', file]);
  assert.notEqual(result.code, 0, `${id} unexpectedly compiled`);
  assert.match(result.output, /Type mismatch|unsolved goals|type mismatch/);
  assert.doesNotMatch(result.output, /unknown module|file not found/i);
  const diagnostic = result.output.replaceAll(out, '<candidate>');
  await writeFile(resolve(out, `${id}.log`), diagnostic);
  examples.push({ id, title, stage: 'Lean proof checker', expected: 'rejected', actual: 'rejected',
    code: `-- Requested task: add export. Candidate patch:\n- n.owner == p.actor && n.tenant == p.tenant\n+ ${replacement}`,
    diagnostic: diagnostic.slice(0, 7000) });
  console.log(`PASS: rejected ${id}`);
}
const admitted = 'import PrivateNotes\nnamespace AgentCandidate\ntheorem bypass : False := by sorry\nend AgentCandidate\n#print axioms AgentCandidate.bypass\n';
const admittedPath = resolve(out, 'admitted.lean'); await writeFile(admittedPath, admitted);
const admittedResult = await run(['env', 'lean', admittedPath]);
assert.equal(admittedResult.code, 0, 'Control: Lean accepts admitted proofs with a warning');
assert.match(admittedResult.output, /sorryAx/);
examples.push({ id: 'sorry', title: 'An agent replaces the proof with sorry', stage: 'Axiom policy (after compilation)',
  expected: 'rejected', actual: 'rejected', code: 'theorem bypass : False := by sorry',
  diagnostic: admittedResult.output.replaceAll(out, '<candidate>') + '\nREJECTED: dependency on sorryAx is not allowed by the trusted gate.' });
const editedSpec = spec.replace('n.owner = p.actor ∧ n.tenant = p.tenant', 'n.tenant = p.tenant');
assert.notEqual(hash(editedSpec), hash(spec));
examples.push({ id: 'spec-edit', title: 'An agent changes the policy itself', stage: 'Protected-input digest check',
  expected: 'rejected', actual: 'rejected', code: '- owner = caller.actor ∧ tenant = caller.tenant\n+ tenant = caller.tenant',
  diagnostic: `REJECTED: candidate policy differs from the reviewed specification.\nTrusted: ${hash(spec)}\nCandidate: ${hash(editedSpec)}\nThis gate must be owned outside the agent-editable patch. Lean alone does not protect file permissions or CI settings.` });
const receipt = { format: 'leanapp-security-evidence-v1', lean: '4.33.0', generatedAt: new Date().toISOString(),
  sources: { [specPath]: hash(spec), [modelPath]: hash(model), 'scripts/check-security.mjs': hash(await readFile(fileURLToPath(import.meta.url))) },
  theoremCount: 9, examples, limits: 'Model proofs and reproducible local patch checks. Native authentication, SQLite/FFI, compilation and deployment configuration remain trusted. No adversarial-agent sandbox or protected CI configuration is claimed.' };
await writeFile(resolve(out, 'evidence.json'), JSON.stringify(receipt, null, 2) + '\n');
await writeFile(resolve(root, '.lake/security/evidence.json'), JSON.stringify(receipt, null, 2) + '\n');
console.log(`PASS: 9 audited theorems; ${examples.length - 1} rejected candidates; receipt ${out}`);
