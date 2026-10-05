#!/usr/bin/env python3
"""Bounded portable domain qualification; optional current DB witness integration."""
import argparse
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser()
parser.add_argument('--db-source', type=Path)
parser.add_argument('--spec-source', type=Path)
args = parser.parse_args()
os.chdir(ROOT)
ENV = dict(os.environ, LEAN_NUM_THREADS='2')
LOGS = ROOT / 'tests/domain/logs'
LOGS.mkdir(parents=True, exist_ok=True)
if args.spec_source:
    source = args.spec_source.resolve() / 'partiful'
    assert (ROOT / 'tests/domain/Partiful.lean').read_bytes() == (source / 'Domain.lean').read_bytes(), 'Domain fixture drift'
    expected_views = (source / 'Views.lean').read_text().replace('import Partiful.Domain', 'import tests.domain.Partiful')
    assert (ROOT / 'tests/domain/PartifulViews.lean').read_text() == expected_views, 'Views fixture drift'
    print('PASS exact authored Domain/Views source', flush=True)

def run(command, label, expected=None, timeout=180):
    result = subprocess.run(command, env=ENV, text=True, capture_output=True, timeout=timeout)
    output = result.stdout + result.stderr
    (LOGS / f'{label}.log').write_text(output)
    if expected is None:
        if "declaration uses `sorry`" in output or "sorryAx" in output:
            raise RuntimeError(f"{label} contains admitted evidence:\n{output}")
        if result.returncode:
            raise RuntimeError(f'{label} failed:\n{output}')
    else:
        if not result.returncode or expected.lower() not in output.lower():
            raise RuntimeError(f'{label} did not reject for {expected!r}:\n{output}')
        for broken in ['object file', 'unknown module prefix', 'failed to open file']:
            if broken in output:
                raise RuntimeError(f'{label} rejected due to import failure:\n{output}')
    print('PASS', label, flush=True)
    return output

run(['lake', 'build', 'LeanApp.Domain.Memory', 'LeanApp.Domain', 'LeanApp.Core', 'LeanContract.Envelope', 'LeanReact.Domain', 'LeanReact.Compiler', 'LeanContract.Browser'], 'build', timeout=1800)
base = subprocess.check_output(['lake', 'env', 'printenv', 'LEAN_PATH'], env=ENV, text=True).strip()
BUILD = ROOT / 'tests/domain/.build'
ENV['LEAN_PATH'] = str(BUILD) + ':' + base
for name in ['Declarations', 'Operations', 'Views', 'Partiful', 'PartifulViews', 'Evolution', 'Browser', 'Axioms', 'PostPart1',
             'SignUpEvolution', 'PostViews', 'Loans', 'CleanSurface']:
    output = BUILD / f'tests/domain/{name}.olean'
    output.parent.mkdir(parents=True, exist_ok=True)
    run(['lake', 'env', 'lean', '-o', str(output), f'tests/domain/{name}.lean'], name)
run(['lake', 'env', 'lean', '--run', 'tests/domain/Main.lean'], 'native-runtime')
# Milestone 2: the post's plain operations on Memory, published generic bodies, envelope.
run(['lake', 'env', 'lean', '--run', 'tests/domain/PostPart1Run.lean'], 'post-runtime')
run(['lake', 'env', 'lean', '--run', 'tests/domain/Envelope.lean'], 'envelope')
# Generality fixture (an unrelated lending-library domain) on Memory.
run(['lake', 'env', 'lean', '--run', 'tests/domain/LoansRun.lean'], 'loans-runtime')
for name, expected in json.loads((ROOT / 'tests/domain/negative/expected.json').read_text()).items():
    run(['lake', 'env', 'lean', f'tests/domain/negative/{name}.lean'], name, expected)
run(['lake', 'env', 'lean', '--run', 'tests/domain/Generate.lean'], 'generate', timeout=1800)
artifacts = {p: p.read_bytes() for p in (ROOT / 'tests/domain/generated').iterdir() if p.is_file()}
run(['lake', 'env', 'lean', '--run', 'tests/domain/Generate.lean'], 'generate-second-process', timeout=1800)
for path, before in artifacts.items():
    assert path.read_bytes() == before, f'nondeterministic output: {path}'
print('PASS deterministic generated LeanJS/contracts', flush=True)
run(['node', '--test', '--test-timeout=15000', 'tests/domain/browser.test.mjs'], 'browser-runtime')
run(['node', '--test', '--test-timeout=15000', 'tests/domain/app.test.mjs'], 'app-browser-runtime')
if args.db_source:
    db = args.db_source.resolve()
    native = ROOT / 'tests/domain/.native-build'
    ENV['LEAN_PATH'] = ':'.join([str(native), str(BUILD), base,
        str(db / '.lake/build/lib/lean'), str(db / '.lake/packages/leansqlite/.lake/build/lib/lean')])
    for module in ['Storage', 'Witness', 'Resources', 'Schema', 'Access']:
        output = native / f'LeanDbDomain/{module}.olean'
        output.parent.mkdir(parents=True, exist_ok=True)
        run(['lake', 'env', 'lean', '-R', str(db / 'adapters/domain'), '-o', str(output),
             str(db / f'adapters/domain/LeanDbDomain/{module}.lean')], f'DB-{module}')
    run(['lake', 'env', 'lean', 'tests/domain/NativeWitness.lean'], 'native-typed-witness')
    run(['lake', 'env', 'lean', 'tests/domain/NativePost.lean'], 'native-post-requirements')
print('PASS domain qualification', flush=True)
