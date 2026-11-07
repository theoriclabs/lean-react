#!/usr/bin/env node
// One build, dev and test command for LeanReact applications.
//
//   leanreact build <Module>… [--page /path=Decl]… [--out dist] [--css file]… [--styles Namespace]… [--title T]
//   leanreact dev   <Module>… [same options] [--port 4173]
//   leanreact test  <Module>… [same options] [--no-build] [--url /path]…
//
// Each <Module> is a Lean module of the application's library (built with `lake build`) that
// declares pages.
// Each `--page /path=Decl` mounts `Decl` (a `Component Unit` or an `Element`) at `/path`; a path
// ending in `/*` also matches everything below it (for client-side routes). Without `--page`,
// `/=<Module>.App` is used. All pages share one bundle. Generation runs from a generator file
// under `.lake/leanreact/`, never from a library module, so `lake build` writes no JavaScript.
import { build as esbuild } from 'esbuild';
import { createServer } from 'node:http';
import { createRequire } from 'node:module';
import { copyFile, mkdir, readFile, stat, writeFile } from 'node:fs/promises';
import { watch } from 'node:fs';
import { basename, extname, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { run } from './process.mjs';

const packageRoot = fileURLToPath(new URL('../', import.meta.url));
const adapter = resolve(packageRoot, 'engine/adapters/leanjs-react.mjs');

function parse(argv) {
  const [command, ...tail] = argv;
  const first = tail.findIndex(arg => arg.startsWith('--'));
  const modules = first < 0 ? tail : tail.slice(0, first);
  const rest = first < 0 ? [] : tail.slice(first);
  const module = modules[0];
  const options = { command, module, modules, pages: [], css: [], styles: [], urls: [], out: 'dist', port: 4173, title: null, build: true };
  for (let i = 0; i < rest.length; i++) {
    const flag = rest[i], value = () => { if (i + 1 >= rest.length) throw new Error(`${flag} needs a value`); return rest[++i]; };
    if (flag === '--page') {
      const [path, decl] = value().split('=');
      if (!path?.startsWith('/') || !decl) throw new Error('--page takes /path=Declaration');
      options.pages.push({ path, decl });
    } else if (flag === '--out') options.out = value();
    else if (flag === '--css') options.css.push(value());
    else if (flag === '--styles') options.styles.push(value());
    else if (flag === '--title') options.title = value();
    else if (flag === '--port') options.port = Number(value());
    else if (flag === '--url') options.urls.push(value());
    else if (flag === '--no-build') options.build = false;
    else throw new Error(`unknown option ${flag}`);
  }
  if (!['build', 'dev', 'test'].includes(command) || !module) throw new Error('usage: leanreact build|dev|test <Module> [options]');
  if (options.pages.length === 0) options.pages.push({ path: '/', decl: `${module}.App` });
  return options;
}

/** A module from the application's dependencies first, then LeanReact's own. */
function load(name, cwd) {
  for (const base of [resolve(cwd, 'package.json'), resolve(packageRoot, 'package.json')]) {
    try { return createRequire(base).resolve(name); } catch { /* next */ }
  }
  throw new Error(`cannot find ${name}; npm install it in the application`);
}

const leanName = decl => decl.split('.').map(part => /^[A-Za-z_][\w'!?]*$/u.test(part) ? part : `«${part}»`).join('.');

export async function buildApp(options, cwd = process.cwd()) {
  const out = resolve(cwd, options.out);
  const work = resolve(cwd, '.lake/leanreact');
  await mkdir(out, { recursive: true });
  await mkdir(work, { recursive: true });
  // 1. Lean: build the library module, then generate from a file outside the library.
  await run('lake', ['build', ...options.modules], { cwd });
  const generated = resolve(work, 'app.lean.mjs');
  const decls = [...new Set(options.pages.map(page => page.decl))];
  const generator = [
    ...options.modules.map(module => `import ${module}`), 'import LeanReact.Compiler', '', 'run_meta do',
    `  LeanJS.writeModule ${JSON.stringify(generated)} #[${decls.map(d => '`' + leanName(d)).join(', ')}]`,
    `    (LeanReact.Compiler.options ${JSON.stringify(adapter)})`,
    ...(options.styles.length ? [`  LeanReact.Compiler.writeStylesheet ${JSON.stringify(resolve(out, 'styles.css'))} #[${options.styles.map(n => '`' + leanName(n)).join(', ')}]`] : []),
    '',
  ].join('\n');
  const generatorPath = resolve(work, 'Generate.lean');
  await writeFile(generatorPath, generator);
  await run('lake', ['env', 'lean', generatorPath], { cwd });
  // 2. One entry for every page, bundled with esbuild.
  const entry = resolve(work, 'main.mjs');
  await writeFile(entry, [
    `import * as React from ${JSON.stringify(load('react', cwd))};`,
    `import { createRoot } from ${JSON.stringify(load('react-dom/client', cwd))};`,
    `import { mountElement } from ${JSON.stringify(adapter)};`,
    `import * as app from './app.lean.mjs';`,
    `const pages = ${JSON.stringify(options.pages)};`,
    'const path = location.pathname.replace(/\\/+$/, "") || "/";',
    'const page = pages.find(p => p.path === path || (p.path.endsWith("/*") && (path + "/").startsWith(p.path.slice(0, -1))));',
    'const value = page && app[page.decl];',
    'const element = value === undefined ? React.createElement("p", { role: "alert" }, "Page not found.")',
    '  : value?.$$typeof ? value : mountElement(value);',
    'createRoot(document.getElementById("root")).render(React.createElement(React.StrictMode, null, element));',
    '',
  ].join('\n'));
  await esbuild({ entryPoints: [entry], outfile: resolve(out, 'app.js'), bundle: true, format: 'esm', platform: 'browser',
    sourcemap: true, target: ['es2022'], logLevel: 'warning', nodePaths: [resolve(cwd, 'node_modules'), resolve(packageRoot, 'node_modules')] });
  // 3. Assets and the page shell.
  const sheets = [];
  if (options.styles.length) sheets.push('styles.css');
  for (const file of options.css) {
    const name = basename(file);
    await copyFile(resolve(cwd, file), resolve(out, name));
    sheets.push(name);
  }
  const title = options.title ?? options.module;
  await writeFile(resolve(out, 'index.html'), [
    '<!doctype html>', '<html lang="en">', '<head>', '<meta charset="utf-8" />',
    '<meta name="viewport" content="width=device-width, initial-scale=1" />', `<title>${title.replace(/[<&]/g, c => c === '<' ? '&lt;' : '&amp;')}</title>`,
    ...sheets.map(sheet => `<link rel="stylesheet" href="/${sheet}" />`),
    '</head>', '<body>', '<div id="root"></div>', '<script type="module" src="/app.js"></script>', '</body>', '</html>', '',
  ].join('\n'));
  console.log(`Built ${options.pages.length} page(s) into ${relative(cwd, out) || '.'}`);
  return out;
}

const mime = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8',
  '.map': 'application/json', '.svg': 'image/svg+xml', '.png': 'image/png', '.json': 'application/json' };

/** Serve `out`; an extension-less path is a client route and gets `index.html`. */
export function serve(out, port) {
  const server = createServer(async (req, res) => {
    try {
      const url = new URL(req.url, 'http://localhost');
      const path = extname(url.pathname) ? url.pathname : '/index.html';
      const file = resolve(out, '.' + decodeURIComponent(path));
      if (!file.startsWith(out + sep)) { res.writeHead(403); res.end(); return; }
      const body = await readFile(file);
      res.writeHead(200, { 'content-type': mime[extname(file)] ?? 'application/octet-stream', 'cache-control': 'no-store' });
      res.end(body);
    } catch (error) {
      res.writeHead(error.code === 'ENOENT' ? 404 : 500);
      res.end(error.code === 'ENOENT' ? 'Not found' : 'Server error');
    }
  });
  return new Promise(done => server.listen(port, '127.0.0.1', () => done(server)));
}

async function dev(options, cwd) {
  const out = await buildApp(options, cwd);
  const server = await serve(out, options.port);
  console.log(`LeanReact: http://127.0.0.1:${server.address().port}`);
  let timer, building = false, pending = false;
  const rebuild = async () => {
    if (building) { pending = true; return; }
    building = true;
    try { await buildApp(options, cwd); console.log('Rebuilt. Refresh the browser.'); }
    catch (error) { console.error(error.message); }
    finally { building = false; if (pending) { pending = false; void rebuild(); } }
  };
  watch(cwd, { recursive: true }, (_event, filename) => {
    if (!filename) return;
    const parts = String(filename).split(/[\\/]/);
    if (parts.some(part => part === '.lake' || part === 'node_modules' || part === '.git') || resolve(cwd, filename).startsWith(out + sep)) return;
    if (/\.(lean|css|mjs|js|html)$/.test(filename)) { clearTimeout(timer); timer = setTimeout(() => void rebuild(), 200); }
  });
}

/** Mount every page in Chromium at desktop and mobile widths; fail on console errors,
 * uncaught errors, unhandled rejections and horizontal overflow. Writes screenshots. */
export async function testApp(options, cwd = process.cwd()) {
  const out = options.build ? await buildApp(options, cwd) : resolve(cwd, options.out);
  const playwright = await import(load('playwright', cwd));
  const { chromium } = playwright.chromium ? playwright : playwright.default;
  const server = await serve(out, 0);
  const base = `http://127.0.0.1:${server.address().port}`;
  const urls = options.urls.length ? options.urls : options.pages.map(page => page.path.replace(/\/\*$/, '/'));
  const shots = resolve(out, 'screenshots');
  await mkdir(shots, { recursive: true });
  const failures = [];
  let browser;
  try {
    browser = await chromium.launch();
    for (const url of urls) {
      for (const [label, viewport] of [['desktop', { width: 1280, height: 800 }], ['mobile', { width: 390, height: 844 }]]) {
        const page = await browser.newPage({ viewport });
        const problems = [];
        page.on('console', message => { if (message.type() === 'error') problems.push(`console error: ${message.text()}`); });
        page.on('pageerror', error => problems.push(`uncaught: ${error.message}`));
        await page.addInitScript(() => window.addEventListener('unhandledrejection', event => console.error(`unhandled rejection: ${event.reason?.message ?? event.reason}`)));
        await page.goto(base + url, { waitUntil: 'networkidle' });
        await page.waitForFunction(() => document.getElementById('root')?.childElementCount > 0, null, { timeout: 10000 }).catch(() => problems.push('nothing rendered'));
        const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
        if (overflow > 0) problems.push(`horizontal overflow of ${overflow}px`);
        const name = (url.replace(/[^\w-]+/g, '-').replace(/^-|-$/g, '') || 'index') + `-${label}.png`;
        await page.screenshot({ path: resolve(shots, name), fullPage: true });
        for (const problem of problems) failures.push(`${url} (${label}, ${viewport.width}px): ${problem}`);
        console.log(`${problems.length ? 'FAIL' : 'ok  '} ${url} at ${label} width → ${relative(cwd, resolve(shots, name))}`);
        await page.close();
      }
    }
  } finally { await browser?.close(); server.close(); }
  if (failures.length) { for (const failure of failures) console.error(failure); throw new Error(`${failures.length} problem(s)`); }
  return out;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const options = parse(process.argv.slice(2));
    if (options.command === 'build') await buildApp(options);
    else if (options.command === 'dev') await dev(options, process.cwd());
    else await testApp(options);
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}
