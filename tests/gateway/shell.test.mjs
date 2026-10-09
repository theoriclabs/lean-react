import test from 'node:test';
import assert from 'node:assert/strict';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {mkdtemp, readFile, writeFile, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join, resolve} from 'node:path';

const run = promisify(execFile);
test('native app shell preserves defaults and serves custom HTML and CSS', {timeout: 120000}, async () => {
  const bundle = await mkdtemp(join(tmpdir(), 'leanreact-shell-'));
  try {
    await writeFile(join(bundle, 'site.css'), 'body{width:100%}');
    const {stdout} = await run('lake', ['env', 'lean', '--run', 'tests/gateway/Shell.lean', bundle],
      {cwd: resolve(import.meta.dirname, '../..'), maxBuffer: 1024 * 1024});
    const result = JSON.parse(stdout);
    assert.equal(result.default, await readFile(new URL('./shell-golden.html', import.meta.url), 'utf8'));
    assert.ok(result.custom.includes('<title>&lt;Shop &amp; &quot;friends&quot;></title>'));
    assert.ok(result.custom.includes('<a href="/?a=&quot;&lt;&amp;">&lt;Home &amp; &quot;friends&quot;></a>'));
    assert.ok(result.custom.includes('<style>body{max-width:none}</style><link rel="stylesheet" href="/assets/site.css"><meta name="application" content="shop"></head>'));
    assert.ok(result.defaultPage.includes('<nav><a href="/">/</a><a href="/books">/books</a></nav>'));
    assert.ok(!result.defaultPage.includes('/books/:book'));
    assert.ok(result.emptyStyle.includes('<style></style>'));
    assert.ok(result.emptyStyle.includes('"\\u003c/script>"'));
    assert.ok(!result.page.includes('<nav>'));
    assert.ok(result.page.includes('id="leanapp-bootstrap"'));
    assert.ok(result.page.includes('src="/assets/app.mjs"'));
    assert.equal(result.cache, 'private, no-store');
    assert.equal(result.css, 'body{width:100%}');
    assert.equal(result.cssType, 'text/css; charset=utf-8');
    assert.equal(result.invalid, 404);
  } finally {await rm(bundle, {recursive: true, force: true});}
});
