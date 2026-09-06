import * as React from 'react';
import { createRoot } from 'react-dom/client';
import * as tickets from '../generated/tickets.mjs';
import { mountElement, ctor } from '../../engine/adapters/leanjs-react.mjs';
import { createTicketsService } from '../adapters/tickets-service.mjs';

const remote = new URLSearchParams(location.search).get('service') === 'native';
const element = remote
  ? mountElement(tickets['Examples.Tickets.Workspace'], ctor('Examples.Tickets.WorkspaceProps.mk', [
    'native-tickets', createTicketsService(),
  ]))
  : mountElement(tickets['Examples.Tickets.App']);
const root = createRoot(document.getElementById('root'));
root.render(React.createElement(React.StrictMode, null, element));
