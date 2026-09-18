import * as React from 'react';
import { createRoot } from 'react-dom/client';
import * as smoke from '../generated/smoke.mjs';
import { mountElement } from '../../engine/adapters/leanjs-react.mjs';

// The routed example lives under /router/. `scripts/dev.mjs` serves this page for every /router/* path so
// deep links and reloads land here; the Lean codec owns the "router" base segment.
const root = createRoot(document.getElementById('router-root'));
root.render(React.createElement(React.StrictMode, null, mountElement(smoke['Examples.Routing.App'])));
