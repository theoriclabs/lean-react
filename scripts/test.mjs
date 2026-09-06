import { run } from './process.mjs';
import { projectRoot } from './build.mjs';

const cwd = projectRoot;
await run('lake', ['build', 'Examples'], { cwd });
await run('lake', ['env', 'lean', '--run', 'tests/Run.lean', 'compiler'], { cwd });
await run('bash', ['tests/ontology/check.sh'], { cwd });
await run('bash', ['tests/runtime/check-lean.sh'], { cwd });
await run('lake', ['env', 'lean', '--run', 'tests/integration/Queries.lean'], { cwd });
await run('lake', ['env', 'lean', '--run', 'tests/integration/Cells.lean'], { cwd });
await run('node', ['--test', 'tests/runtime/*.test.mjs'], { cwd });
await run('lake', ['env', 'lean', '-R', 'examples/lean', 'examples/lean/Examples/Smoke.lean'], { cwd });
await run('lake', ['env', 'lean', '-R', 'examples/lean', 'examples/lean/Examples/GenerateDomain.lean'], { cwd });
await run('lake', ['env', 'lean', '-R', 'examples/lean', 'examples/lean/Examples/Generate.lean'], { cwd });
await run('node', ['--test', 'tests/integration/*.test.mjs'], { cwd });
await run('node', ['node_modules/typescript/bin/tsc', '--noEmit'], { cwd });
