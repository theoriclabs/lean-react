#!/usr/bin/env bash
# Optional offline qualification using an explicitly built runtime checkpoint.
# The primary supported check is npm run test:framework:native (ordinary Lake).
set -euo pipefail
cd "$(dirname "$0")/../.."
: "${LEANDB_STAGED_ROOT:?Set LEANDB_STAGED_ROOT to the runtime checkpoint source checkout}"
: "${LEANDB_CACHE_ROOT:?Set LEANDB_CACHE_ROOT to the compatible upstream cache checkout}"
python3 - <<'PY'
import hashlib, json, os, pathlib, re, shutil, subprocess, tempfile

root = pathlib.Path.cwd()
native = root / 'adapters/native'
staged = pathlib.Path(os.environ['LEANDB_STAGED_ROOT']).resolve()
cache = pathlib.Path(os.environ['LEANDB_CACHE_ROOT']).resolve()
sqlite = cache / '.lake/packages/leansqlite'
runtime = staged / '.lake/runtime-callbacks/build'
if not (runtime / 'lib/lean/LeanDb/Runtime.olean').is_file():
    raise SystemExit('Runtime checkpoint unavailable; run its scripts/check_runtime_callbacks.sh --native first. No ABI fallback is permitted.')
if shutil.disk_usage(root).free < 600 * 1024 * 1024:
    raise SystemExit('Managed native checks require at least 600 MiB free.')
out_parent = native / '.lake/managed-checks'
out_parent.mkdir(parents=True, exist_ok=True)
out = pathlib.Path(tempfile.mkdtemp(prefix='run.', dir=out_parent))
lib, ir = out / 'lib/lean', out / 'ir'
lib.mkdir(parents=True)
ir.mkdir()
fixture = out / 'fixture'
fixture.mkdir()
env = dict(os.environ, LEAN_PATH=os.pathsep.join(map(str, [lib, runtime / 'lib/lean',
    cache / '.lake/build/lib/lean', sqlite / '.lake/build/lib/lean'])))
sources, order, imported = {}, [], {}

def visit(name):
    if name in sources:
        return
    relative = pathlib.Path(*name.split('.')).with_suffix('.lean')
    if name == 'SQLite' or name.startswith('SQLite.'):
        source = sqlite / relative
    elif name == 'LeanDb' or name.startswith('LeanDb.'):
        source = staged / relative
    elif name == 'ManagedChecks' or name.startswith('LeanAppNative.'):
        source = native / relative
    else:
        source = root / 'engine' / relative
    sources[name] = source
    for dep in re.findall(r'^(?:public |meta )?import\s+([\w.]+)', source.read_text(), re.M):
        if dep.startswith(('LeanDb', 'SQLite', 'LeanOntology', 'LeanContract', 'LeanApp')):
            visit(dep)
    order.append(name)

visit('ManagedChecks')
objects, modules = [], []

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

receipt = {
    'task': 'FS08 managed application dispatcher (bounded synchronous adapter qualification)',
    'staged_source': str(staged), 'runtime_build': str(runtime), 'readonly_cache': str(cache),
    'changed_files': ['adapters/native/LeanAppNative/Managed.lean', 'adapters/native/ManagedChecks.lean',
                      'adapters/native/check-managed.sh', 'adapters/native/lakefile.lean'],
    'limitations': [
        'No production authentication, listeners, signals, outbox, deployment or FS08-wide completion claim.',
        'Transactions remain explicit handler responsibility; factory and handlers are trusted synchronous native code.',
        'Connection replacement is exercised under the owner lock; actual restore lifecycle qualification belongs to upstream worker.',
        'This optional checkpoint check does not replace the ordinary Lake build against integrated dependencies.'
    ],
    'modules': modules, 'free_before': shutil.disk_usage(root).free,
}
receipt_path = out / 'receipt.json'

try:
    for name in order:
        relative = pathlib.Path(*name.split('.'))
        external = name == 'SQLite' or name.startswith(('SQLite.', 'LeanDb.')) or name == 'LeanDb'
        source = sources[name]
        item = {'module': name, 'source': str(source), 'source_sha256': digest(source), 'external_readonly': external}
        modules.append(item)
        if external:
            dependency_root = sqlite if name.startswith('SQLite') else cache
            olean = runtime / 'lib/lean' / relative.with_suffix('.olean')
            # The staged runtime runner records ABI-dependent modules here; absent entries
            # cannot silently fall back to an older upstream interface.
            if not olean.is_file():
                raise RuntimeError(f'Missing staged dependency artifact: {olean}')
            obj = runtime / 'ir' / relative.with_suffix('.c.o')
            if not obj.is_file():
                if not olean.is_symlink():
                    raise RuntimeError(f'Native staged object unavailable for rebuilt module: {name}')
                obj = dependency_root / '.lake/build/ir' / relative.with_suffix('.c.o.export')
            if not obj.is_file():
                raise RuntimeError(f'Missing read-only native object: {obj}')
            for artifact in (olean, obj):
                imported[str(artifact)] = digest(artifact)
            item.update(olean=str(olean), object=str(obj), olean_sha256=digest(olean), object_sha256=digest(obj))
            objects.append(str(obj))
            continue
        if shutil.disk_usage(root).free < 400 * 1024 * 1024:
            raise RuntimeError('Stopped before compilation: less than 400 MiB free')
        target = lib / relative.with_suffix('.olean')
        c = ir / relative.with_suffix('.c')
        obj = ir / relative.with_suffix('.o')
        setup = ir / relative.with_suffix('.setup.json')
        target.parent.mkdir(parents=True, exist_ok=True)
        c.parent.mkdir(parents=True, exist_ok=True)
        setup.write_text(json.dumps({'name': name, 'package': 'leanapp_native', 'isModule': False,
            'importArts': {}, 'dynlibs': [], 'plugins': [], 'options': {}}))
        print(f'Compile {name}', flush=True)
        subprocess.run(['lean', '--setup', str(setup), '-o', str(target), '-c', str(c), str(source)], env=env, check=True)
        subprocess.run(['leanc', '-O1', '-c', str(c), '-o', str(obj)], check=True)
        objects.append(str(obj))
    binary = out / 'managed_checks'
    command = ['leanc', '-o', str(binary), *objects, str(sqlite / '.lake/build/lib/libleansqlite.a'),
               '-lLean', '-lStd', '-lLake']
    receipt['link_command'] = command
    for path, checksum in imported.items():
        if digest(pathlib.Path(path)) != checksum:
            raise RuntimeError(f'Staged artifact changed during compilation; rerun after worker finishes: {path}')
    subprocess.run(command, check=True)
    receipt['binary_sha256'] = digest(binary)
    receipt['test_command'] = [str(binary), str(fixture)]
    print(f'Run managed checks; receipt: {receipt_path}', flush=True)
    with (out / 'results.log').open('w') as log:
        result = subprocess.run(receipt['test_command'], stdout=log, stderr=subprocess.STDOUT, timeout=90)
    output = (out / 'results.log').read_text()
    print(output, end='')
    receipt['exit_code'] = result.returncode
    receipt['passed_assertions'] = len(re.findall(r'^PASS: ', output, re.M))
    receipt['readonly_artifacts_unchanged'] = all(digest(pathlib.Path(p)) == h for p, h in imported.items())
    result.check_returncode()
    if not receipt['readonly_artifacts_unchanged']:
        raise RuntimeError('External artifacts changed during checks; rerun with a stable staged build')
except Exception as error:
    receipt['failure'] = str(error)
    raise
finally:
    receipt['free_after'] = shutil.disk_usage(root).free
    receipt_path.write_text(json.dumps(receipt, indent=2) + '\n')
    print(f'Durable receipt: {receipt_path}', flush=True)
PY
