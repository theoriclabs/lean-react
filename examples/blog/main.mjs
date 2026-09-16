import { createRoot } from 'react-dom/client';
import { mountElement } from '../../engine/adapters/leanjs-react.mjs';
import * as demos from '../generated/blog.mjs';

const components = {
  counter: 'Examples.Blog.CounterDemo',
  states: 'Examples.Blog.ResourceDemo',
  editors: 'Examples.Blog.EditorDemo',
  forms: 'Examples.Blog.FormDemo',
};
const host = document.getElementById('demo');
if (host) createRoot(host).render(mountElement(demos[components[host.dataset.demo]]));
