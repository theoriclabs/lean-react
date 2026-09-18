import { mkdir, readFile, writeFile, copyFile, cp } from 'node:fs/promises';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { build } from 'esbuild';
import { run } from './process.mjs';

const root = fileURLToPath(new URL('../', import.meta.url));
const output = resolve(root, 'docs/blog/demos');
const generated = resolve(root, 'examples/generated');
await mkdir(resolve(output, 'assets'), { recursive: true });
await mkdir(generated, { recursive: true });
await run('lake', ['build', 'LeanReact.Compiler', 'Examples.Blog'], { cwd: root });
const generator = resolve(root, '.lake/GenerateBlog.lean');
await writeFile(generator, `import LeanReact.Compiler
import Examples.Blog
run_meta do
  LeanJS.writeModule "examples/generated/blog.mjs"
    #[\`Examples.Blog.CounterDemo, \`Examples.Blog.ResourceDemo,
      \`Examples.Blog.EditorDemo, \`Examples.Blog.FormDemo]
    (LeanReact.Compiler.options "../../engine/adapters/leanjs-react.mjs")
`);
await run('lake', ['env', 'lean', generator], { cwd: root });
await build({
  absWorkingDir: root, entryPoints: ['examples/blog/main.mjs'],
  outfile: resolve(output, 'assets/demo.js'), bundle: true, format: 'iife',
  platform: 'browser', target: ['es2022'], minify: true,
  define: { 'process.env.NODE_ENV': '"production"' },
});
await copyFile(resolve(root, 'examples/blog/style.css'), resolve(output, 'assets/style.css'));
await copyFile(resolve(root, 'examples/web/favicon.svg'), resolve(output, 'assets/favicon.svg'));

const post = await readFile(resolve(root, 'docs/blog/introduction_post.md'), 'utf8');
const snippets = [...post.matchAll(/^```lean\n([\s\S]*?)\n```/gm)].map(match => match[1]);
const demoSource = await readFile(resolve(root, 'examples/lean/Examples/Blog.lean'), 'utf8');
const pages = [
  { id: 'counter', name: 'Counter', title: 'A little Lean. A real button.',
    description: 'Click the button. Each click updates state in a Lean component, rendered by React.',
    note: 'Try a few clicks. Reload the page to start again.',
    after: 'The button is the Counter component from the post. Its click handler adds one to the current count.',
    image: 'counter', source: snippets[0] },
  { id: 'states', name: 'Loading states', title: 'Every state gets a place.',
    description: 'Choose a state to see what the ticket list shows. Try Empty and Failure: they tell two different stories.',
    note: 'These controls select example states. They do not make network requests.',
    after: 'Empty is a successful request with no tickets. Failure means we could not load them. The same match handles both.',
    image: 'resource-states', source: snippets[1] },
  { id: 'editors', name: 'Swap editors', title: 'Change the input. Keep the draft.',
    description: 'Edit the title, then switch to a textarea. The text you typed stays with the parent component.',
    note: 'Both inputs accept an Editor String binding.',
    after: 'TitleField keeps the draft. The editor prop chooses how to display it. Switching the prop keeps the same parent mounted.',
    image: 'editors', source: snippets[2] },
  { id: 'forms', name: 'Form validation', title: 'Let people finish typing.',
    description: 'Clear the title and try to save. Then type a new title and save again.',
    note: 'This is a local demo. Nothing is sent to a server.',
    after: 'The form keeps invalid text while you edit. The save callback runs only after the title passes validation.',
    image: 'draft-validation', source: demoSource.slice(demoSource.indexOf('def FormDemo'), demoSource.indexOf('\nend Examples.Blog')).trim() },
];
const escape = value => value.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');
const highlight = source => escape(source)
  .replace(/(&quot;.*?&quot;)/g, '<span class="str">$1</span>')
  .replace(/\b(import|open|structure|where|def|do|let|pure|fun|match|with|if|then|else)\b/g, '<span class="kw">$1</span>');
const nav = active => `<nav class="section-nav" aria-label="Examples">${pages.map(page => {
  const href = active === 'index' ? `#${page.id}` : `${page.id}.html`;
  return `<a href="${href}"${page.id === active ? ' aria-current="page"' : ''}>${page.name}</a>`;
}).join('')}</nav>`;
const document = (title, description, active, content) => `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${escape(title)} · LeanReact</title><meta name="description" content="${escape(description)}">
<link rel="icon" href="assets/favicon.svg" type="image/svg+xml"><link rel="stylesheet" href="assets/style.css">
</head><body class="${active}-page"><a class="skip-link" href="#main">Skip to example</a><div class="shell">
<header class="masthead"><a class="wordmark" href="index.html"><span class="mark" aria-hidden="true">λ</span>LeanReact</a><a href="https://github.com/theoriclabs/lean-react">Source on GitHub ↗</a></header>
${nav(active)}<main id="main">${content}</main>
<footer class="page-footer"><span>Written in Lean. Rendered by React.</span><a href="index.html">All examples</a></footer>
</div><script defer src="assets/demo.js"></script></body></html>\n`;
for (const [index, page] of pages.entries()) {
  const next = pages[(index + 1) % pages.length];
  await copyFile(resolve(root, `docs/blog/images/introduction/${page.image}.png`), resolve(output, `assets/${page.image}.png`));
  await writeFile(resolve(output, `${page.id}.html`), document(page.title, page.description, page.id, `
<p class="eyebrow">Example ${String(index + 1).padStart(2, '0')} / Try it</p>
<h1>${page.title}</h1><p class="lede">${page.description}</p>
<div class="stage"><section class="panel" aria-label="Live example"><div class="panel-bar"><span>Live component</span><span class="badge">LEAN + REACT</span></div><div class="live-body"><div id="demo" data-demo="${page.id}"></div><noscript>Enable JavaScript to try this example. The Lean source is shown alongside it.</noscript></div><p class="live-note">${page.note}</p></section>
<section class="panel source" aria-label="Lean source"><div class="panel-bar"><span>${page.id === 'forms' ? 'FormDemo' : 'From the blog post'}</span><span class="badge">.lean</span></div><pre><code>${highlight(page.source)}</code></pre></section></div>
<p class="after">${page.after}</p><nav class="next" aria-label="More examples"><a href="index.html">← All examples</a><a href="${next.id}.html">Next: ${next.name} →</a></nav>`));
}
await writeFile(resolve(output, 'index.html'), document('Try the examples', 'Four small, interactive examples from the LeanReact introduction.', 'index', `
<p class="eyebrow">The introduction, in your browser</p><h1>Try the examples.</h1><p class="lede">Click a counter, choose a loading state, swap an editor, or try saving an empty title.</p>
<div class="tiles">${pages.map(page => `<article class="tile ${page.id}-demo" id="${page.id}"><div class="tile-live"><div class="tile-live-bar"><span>Live component</span><span class="badge">LEAN + REACT</span></div><div class="tile-live-body"><div data-demo="${page.id}"></div><noscript>Enable JavaScript to try this example.</noscript></div></div><div class="tile-copy"><h2>${page.name}</h2><p>${page.description}</p><a href="${page.id}.html">See the Lean source →</a></div></article>`).join('')}</div>`));
// Keep a standard static output directory for the Sites hosting manifest.
await mkdir(resolve(output, 'dist'), { recursive: true });
for (const file of ['index.html', ...pages.map(page => `${page.id}.html`), 'assets'])
  await cp(resolve(output, file), resolve(output, 'dist', file), { recursive: true });
console.log(`Built ${pages.length} interactive demo pages and an index in docs/blog/demos/.`);
