import * as React from 'react';
import { createRoot } from 'react-dom/client';
import * as tickets from '../generated/tickets.mjs';
import * as collections from '../generated/collections.mjs';
import * as libraries from '../generated/libraries.mjs';
import * as smoke from '../generated/smoke.mjs';
import counterSource from '../lean/Examples/Showcase.lean';
import ticketsSource from '../lean/Examples/Tickets/Components.lean';
import collectionsSource from '../lean/Examples/Collections.lean';
import librariesSource from '../lean/Examples/Libraries/App.lean';
import { mountElement, ctor } from '../../engine/adapters/leanjs-react.mjs';
import { createTicketsService } from '../adapters/tickets-service.mjs';

const parameters = new URLSearchParams(location.search);
const remote = parameters.get('service') === 'native';
const examples = {
  tickets: {
    description: 'Swap the layout, footer, or field editor. The same components and domain values carry through.',
    file: 'Tickets/Components.lean', source: ticketsSource,
    start: 'def ListView', end: 'structure CardProps',
  },
  collections: {
    description: 'Add a row, leave a field empty, then reverse the list. Validation follows the data; state follows the key.',
    file: 'Collections.lean', source: collectionsSource,
    start: 'def RowsEditor', end: 'private def errorText',
  },
  libraries: {
    description: 'Change the provider heading. A consumer compiled in another library receives the update through one shared context.',
    file: 'Libraries/App.lean', source: librariesSource,
    start: 'def App', end: '-- Only this component',
  },
};
const requestedExample = parameters.get('example');
const example = Object.hasOwn(examples, requestedExample) ? requestedExample : 'tickets';
const selection = examples[example];
document.getElementById('root').dataset.example = example;
document.getElementById('example-description').textContent = selection.description;
document.getElementById('example-source-name').textContent = selection.file;
document.getElementById('example-source-link').href = `https://github.com/theoriclabs/lean-react/blob/main/examples/lean/Examples/${selection.file}`;
for (const link of document.querySelectorAll('[data-example]')) {
  if (link.tagName !== 'A') continue;
  if (link.dataset.example === example) link.setAttribute('aria-current', 'page');
  if (remote) {
    const url = new URL(link.href);
    url.searchParams.set('service', 'native');
    link.href = url.href;
  }
}
if (remote && example === 'tickets') {
  document.getElementById('persistence-note').textContent = 'Connected to the local LeanDB / LeanHttp service. Saved changes persist across refreshes.';
}

// Display the actual Lean definitions bundled from source, with a small local lexer.
function excerpt(source, start, end) {
  const begin = source.indexOf(start);
  const finish = source.indexOf(end, begin);
  if (begin < 0 || finish < 0) throw new Error(`Missing source excerpt: ${start}`);
  return source.slice(begin, finish).trim();
}
function highlight(element, source) {
  const tokens = /--[^\n]*|"(?:\\.|[^"\\])*"|\b(?:def|let|pure|fun|do|some|none|if|then|else|structure|where|import|open)\b|\b\d+\b/g;
  let offset = 0;
  for (const match of source.matchAll(tokens)) {
    element.append(document.createTextNode(source.slice(offset, match.index)));
    const span = document.createElement('span');
    const token = match[0];
    span.className = token.startsWith('--') ? 'syntax-comment' : token.startsWith('"') ? 'syntax-string'
      : /^\d/.test(token) ? 'syntax-number' : 'syntax-keyword';
    span.textContent = token;
    element.append(span);
    offset = match.index + token.length;
  }
  element.append(document.createTextNode(source.slice(offset)));
}
highlight(document.getElementById('counter-source'), excerpt(counterSource, 'def Counter', 'end Examples.Showcase'));
highlight(document.getElementById('example-source'), excerpt(selection.source, selection.start, selection.end));

document.getElementById('copy-install').addEventListener('click', async event => {
  const button = event.currentTarget;
  const commands = document.getElementById('install-commands');
  try {
    await navigator.clipboard.writeText(commands.textContent.trim());
    button.textContent = 'Copied!';
    document.getElementById('copy-status').textContent = 'Setup commands copied to the clipboard.';
  } catch {
    const range = document.createRange();
    range.selectNodeContents(commands);
    const selection = window.getSelection();
    selection.removeAllRanges();
    selection.addRange(range);
    button.textContent = 'Commands selected';
    document.getElementById('copy-status').textContent = 'Copy the selected commands using your keyboard.';
  }
});
const element = example === 'collections' ? mountElement(collections['Examples.Collections.App'])
  : example === 'libraries' ? mountElement(libraries['Examples.Libraries.App']) : remote
  ? mountElement(tickets['Examples.Tickets.Workspace'], ctor('Examples.Tickets.WorkspaceProps.mk', [
    'native-tickets', createTicketsService(),
  ]))
  : mountElement(tickets['Examples.Tickets.App']);
const root = createRoot(document.getElementById('root'));
root.render(React.createElement(React.StrictMode, null, element));
createRoot(document.getElementById('hero-root')).render(
  React.createElement(React.StrictMode, null, mountElement(smoke['Examples.Showcase.Counter'])));
