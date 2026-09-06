// Independent Node consumer: this generated module has no React/browser imports.
import * as domain from '../generated/domain.mjs';

const seed = domain['Examples.Tickets.seed'];
if (seed.tag !== 'Except.ok') throw new Error('Invalid example fixture');
const tickets = seed.fields[0];
const renderTitles = domain['Examples.Tickets.renderTitles'];
const countOpen = domain['Examples.Tickets.countOpen'];

console.log(JSON.stringify({
  open: countOpen(tickets).toString(),
  subjects: renderTitles(title => `[Tickets] ${title.fields[0]}`, tickets),
}, null, 2));
