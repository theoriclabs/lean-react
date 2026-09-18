import { createRoot } from 'react-dom/client';
import { mountElement } from '../../engine/adapters/leanjs-react.mjs';
import * as demos from '../generated/blog.mjs';

const components = {
  counter: 'Examples.Blog.CounterDemo',
  states: 'Examples.Blog.ResourceDemo',
  editors: 'Examples.Blog.EditorDemo',
  forms: 'Examples.Blog.FormDemo',
};
for (const host of document.querySelectorAll('[data-demo]')) {
  const name = components[host.dataset.demo];
  if (name) createRoot(host).render(mountElement(demos[name]));
}
