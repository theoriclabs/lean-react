#!/usr/bin/env python3
"""The LeanReact.Domain gate: the endpoint surface (`form`, `call`, `load`, `App`), its
compile-time rejections, the compiled browser fixtures and the mounted browser tests.

The domain and operations the fixtures use are LeanAPI's (`TestsCore.PostPart1`, built in the
leanapi checkout this repository requires). Fixture modules compile to `tests/domain/.build`
and are found first on the search path (`lean`, not `lake env lean`, so that path comes
before the dependencies' own `Tests*` directories on a case-insensitive file system)."""
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parent.parent
os.chdir(ROOT)
ENV = dict(os.environ, LEAN_NUM_THREADS='2')
LOGS = ROOT / 'tests/domain/logs'
LOGS.mkdir(parents=True, exist_ok=True)

def run(command, label, expected=None, timeout=300):
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

run(['lake', 'build', 'LeanReact', 'LeanReact.Domain', 'LeanJS', 'leanapi/TestsCore'], 'build', timeout=1800)
base = subprocess.check_output(['lake', 'env', 'printenv', 'LEAN_PATH'], env=ENV, text=True).strip()
BUILD = ROOT / 'tests/domain/.build'
ENV['LEAN_PATH'] = str(BUILD) + ':' + base
for name in ['PostViews', 'SignUpEvolution', 'Browser']:
    output = BUILD / f'tests/domain/{name}.olean'
    output.parent.mkdir(parents=True, exist_ok=True)
    run(['lean', '-o', str(output), f'tests/domain/{name}.lean'], name)
for name, expected in json.loads((ROOT / 'tests/domain/negative/expected.json').read_text()).items():
    run(['lean', f'tests/domain/negative/{name}.lean'], name, expected)
run(['lean', '--run', 'tests/domain/Generate.lean'], 'generate', timeout=1800)
artifacts = {p: p.read_bytes() for p in (ROOT / 'tests/domain/generated').rglob('*') if p.is_file()}
run(['lean', '--run', 'tests/domain/Generate.lean'], 'generate-second-process', timeout=1800)
for path, before in artifacts.items():
    assert path.read_bytes() == before, f'nondeterministic output: {path}'
print('PASS deterministic generated LeanJS/contracts', flush=True)
run(['node', '--test', '--test-timeout=15000', 'tests/domain/browser.test.mjs'], 'browser-runtime')
run(['node', '--test', '--test-timeout=15000', 'tests/domain/app.test.mjs'], 'app-browser-runtime')
print('PASS LeanReact.Domain qualification', flush=True)
