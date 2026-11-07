// The Part 1 post's app (`partiful_v2/`, staged by scripts/stage-partiful.py as a full-stack
// LeanReact app: `app% server where app := app`) over real HTTP, SQLite and Chromium, with the
// post's semantics: plain JSON bodies, the {"ok"}/{"error"} envelope, cookie, bearer and token
// sessions, the server clock, the guest list visibility matrix, Party.Changes, reschedule and
// cancel errors, the RSVP cascade, the migration gate on a real pre-`guestList` database,
// restart, and the compiled LeanReact `App` in Chromium. The pre-`guestList` app is LeanAPI's
// fixture (`leanapi_apps partiful-before`), run from the leanapi checkout.
// Usage: node scripts/partiful-acceptance.mjs [WORKSPACE] [NODE_MODULES] [--only SECTION]
import assert from 'node:assert/strict';
import {spawn, spawnSync} from 'node:child_process';
import {createServer} from 'node:net';
import {mkdir, writeFile, copyFile} from 'node:fs/promises';
import {resolve, join} from 'node:path';
import {pathToFileURL, fileURLToPath} from 'node:url';
import {randomBytes} from 'node:crypto';

const leanreact = resolve(fileURLToPath(new URL('..', import.meta.url)));
const positional = process.argv.slice(2).filter((arg, index, all) => !arg.startsWith('--') && all[index - 1] !== '--only');
const workspace = resolve(positional[0] ?? join(leanreact, '.lake/partiful-app'));
const nodeModules = resolve(positional[1] ?? join(leanreact, 'node_modules'));
const leanapi = resolve(leanreact, '../leanapi');
const only = process.argv.indexOf('--only') > 0 ? process.argv[process.argv.indexOf('--only') + 1] : null;
const bin = name => join(name === 'leanapi_apps' ? leanapi : workspace, '.lake/build/bin', name);
const run = resolve(leanreact, '.lake/partiful-acceptance', randomBytes(8).toString('hex'));
await mkdir(run, {recursive: true});
const clock = join(run, 'clock');
await writeFile(clock, '100');
const freePort = async () => {
  const socket = createServer();
  await new Promise(done => socket.listen(0, '127.0.0.1', done));
  const port = socket.address().port;
  await new Promise(done => socket.close(done));
  return port;
};
const port = await freePort();
const origin = `http://127.0.0.1:${port}`;
const counts = {};
let section = 'setup';
const eq = (actual, expected, label) => {counts[section] = (counts[section] ?? 0) + 1; assert.deepEqual(actual, expected, `[${section}] ${label}`);};
const check = (condition, label) => {counts[section] = (counts[section] ?? 0) + 1; assert.ok(condition, `[${section}] ${label}`);};
const pause = ms => new Promise(done => setTimeout(done, ms));
const setClock = seconds => writeFile(clock, String(seconds));
// RFC 3339 for a clock second.
const at = seconds => new Date(seconds * 1000).toISOString().replace('.000Z', 'Z');

// The development overrides only point the binary at this run's database, clock and port; it
// finds its own browser bundle (no LEANAPP_BROWSER_DIR).
const {LEANAPP_BROWSER_DIR, ...inherited} = process.env;
const envFor = database => ({...inherited, LEANAPP_DATABASE: database, LEANAPP_CLOCK_FILE: clock, LEANAPP_PORT: String(port)});
async function start(exe, database, args = []) {
  const child = spawn(bin(exe), args, {cwd: run, env: envFor(database), stdio: ['ignore', 'pipe', 'pipe']});
  let out = '';
  child.stdout.on('data', bytes => {out += bytes;});
  child.stderr.on('data', bytes => {out += bytes;});
  const exited = new Promise(done => child.once('exit', code => done(code)));
  const deadline = performance.now() + 20000;  // awake time: a system sleep does not count
  while (!out.includes('leanapi.ready')) {
    if (child.exitCode !== null) return {exitCode: await exited, log: () => out};
    if (performance.now() > deadline) throw new Error(`${exe} readiness timeout\n${out}`);
    await pause(20);
  }
  return {log: () => out, stop: async () => {if (child.exitCode === null) {child.kill('SIGTERM'); await exited;}}};
}
const command = (exe, database, ...args) => spawnSync(bin(exe), args, {cwd: run, env: envFor(database), encoding: 'utf8'});
function sql(database, statement, parameters = []) {
  const result = spawnSync('python3', ['-c',
    'import sqlite3,json,sys\nc=sqlite3.connect(sys.argv[1]); q=json.loads(sys.argv[2]); r=c.execute(q[0],q[1]); rows=r.fetchall(); c.commit(); print(json.dumps(rows))',
    database, JSON.stringify([statement, parameters])], {encoding: 'utf8'});
  if (result.status !== 0) throw new Error(`sqlite: ${result.stderr}`);
  return JSON.parse(result.stdout);
}
const columns = (database, table) => sql(database, `PRAGMA table_info("${table}")`).map(row => row[1]);

class Jar {
  cookies = new Map();
  header() {return [...this.cookies].map(([key, value]) => `${key}=${value}`).join('; ');}
  csrf() {return this.cookies.get('leanapp_csrf');}
  receive(response) {
    for (const raw of response.headers.getSetCookie()) {
      const pair = raw.split(';')[0], index = pair.indexOf('=');
      this.cookies.set(pair.slice(0, index), pair.slice(index + 1));
    }
  }
}
// One HTTP request. `as` is a bearer token, a cookie Jar (sent with Origin and the CSRF
// header, like the browser), or nothing. `token: true` asks for the token reply.
async function http(method, path, {body, as, token = false, headers = {}, omit = []} = {}) {
  let sent = {};
  if (body !== undefined) sent['content-type'] = 'application/json';
  if (token) sent.accept = 'application/vnd.leanapp.token';
  if (typeof as === 'string') sent.authorization = `Bearer ${as}`;
  if (as instanceof Jar) {
    sent.origin = origin;
    if (as.header()) sent.cookie = as.header();
    if (as.csrf()) sent['x-csrf-token'] = as.csrf();
  }
  sent = {...sent, ...headers};
  for (const key of omit) delete sent[key];
  const response = await fetch(origin + path, {method, headers: sent, redirect: 'manual',
    body: body === undefined ? undefined : (typeof body === 'string' ? body : JSON.stringify(body))});
  const text = await response.text();
  if (as instanceof Jar) as.receive(response);
  let json = null;
  try {json = JSON.parse(text);} catch {}
  return {status: response.status, text, body: json, headers: response.headers, cookies: response.headers.getSetCookie()};
}
const post = (path, body, options = {}) => http('POST', path, {body, ...options});
const get = (path, options = {}) => http('GET', path, options);
const ok = (result, value, label) => eq([result.status, result.body], [200, {ok: value}], label);
const fails = (result, error, label, status = 422) => {
  eq([result.status, result.body], [status, {error}], label);
  eq(result.cookies.length, 0, `${label}: no cookies`);
};
const password = 'correct horse battery staple';
async function tokenSignUp(name, email) {
  const result = await post('/sign-up', {name, email, password}, {token: true});
  eq(result.status, 200, `token sign-up ${name}`);
  return {id: result.body.ok.profile, token: result.body.ok.token};
}
const party = (title, date, guestList = 'everyone') => ({title, description: `About ${title}`, date: at(date), guestList});

function report() {
  const total = Object.values(counts).reduce((a, b) => a + b, 0);
  for (const [name, count] of Object.entries(counts)) console.log(`  ${name}: ${count}`);
  console.log(`PASS: ${total} partiful_v2 acceptance checks (pages, HTTP, SQLite, Chromium); run ${run}`);
}

const database = join(run, 'partiful.sqlite');
let server = null, browser = null;
try {
  if (!only || only === 'http') {
    server = await start('partiful', database);
    check(server.stop, 'partiful serves a fresh database');
    // ---------------------------------------------------------------- sign-up and sign-in
    section = 'auth';
    const asha = await tokenSignUp('Asha', 'asha@example.com');
    eq(asha.id, 1, 'first profile reference');
    check(typeof asha.token === 'string' && asha.token.length >= 40, 'token reply carries the session token');
    const ben = await tokenSignUp('Ben', 'ben@example.com');
    const cara = await tokenSignUp('Cara', 'cara@example.com');
    const tokenReply = await post('/sign-up', {name: 'Eve', email: 'eve@example.com', password}, {token: true});
    eq(tokenReply.cookies.length, 0, 'token sign-up sets no cookie');
    eq(tokenReply.headers.get('x-leanapp-auth-csrf'), null, 'token sign-up has no CSRF marker');
    const eve = {id: tokenReply.body.ok.profile, token: tokenReply.body.ok.token};
    // Cookie mode: the browser's default.
    const dana = new Jar();
    const danaUp = await post('/sign-up', {name: 'Dana', email: 'dana@example.com', password}, {as: dana});
    ok(danaUp, 5, 'cookie sign-up replies with the profile reference');
    check(dana.cookies.get('leanapp_session') && dana.csrf(), 'cookie sign-up sets the session and CSRF cookies');
    check(danaUp.cookies.some(c => c.startsWith('leanapp_session=') && /HttpOnly/i.test(c) && /SameSite=Strict/i.test(c)), 'session cookie is HttpOnly and SameSite=Strict');
    check(danaUp.cookies.some(c => c.startsWith('leanapp_csrf=') && !/HttpOnly/i.test(c)), 'CSRF cookie is readable');
    eq(danaUp.headers.get('x-leanapp-auth-csrf'), dana.csrf(), 'auth marker matches the CSRF cookie');
    check(!danaUp.text.includes(dana.cookies.get('leanapp_session')), 'the session token is never in a cookie-mode body');
    eq((await post('/sign-up', {name: 'Nobody', email: 'nobody@example.com', password})).status, 403,
      'cookie-mode sign-up without Origin is refused');
    fails(await post('/sign-up', {name: 'Not Asha', email: 'asha@example.com', password}, {token: true}), 'emailTaken', 'token sign-up with a taken email');
    fails(await post('/sign-up', {name: 'Not Asha', email: 'asha@example.com', password}, {as: new Jar()}), 'emailTaken', 'cookie sign-up with a taken email');
    eq(sql(database, 'SELECT count(*) FROM person WHERE email=?', ['asha@example.com'])[0][0], 1, 'a refused sign-up leaves one person');
    eq(sql(database, 'SELECT count(*) FROM person')[0][0], sql(database, 'SELECT count(*) FROM credential')[0][0], 'every person has a credential (sign-up is one transaction)');
    // Sign-in, both modes.
    const danaIn = new Jar();
    ok(await post('/sign-in', {email: 'dana@example.com', password}, {as: danaIn}), 5, 'cookie sign-in');
    check(danaIn.cookies.get('leanapp_session') !== dana.cookies.get('leanapp_session'), 'sign-in starts a new session');
    const ashaIn = await post('/sign-in', {email: 'asha@example.com', password}, {token: true});
    eq([ashaIn.status, ashaIn.body.ok.profile], [200, 1], 'token sign-in');
    check(ashaIn.body.ok.token !== asha.token, 'token sign-in issues a new token');
    // Unknown email and wrong password are the same reply.
    const unknown = await post('/sign-in', {email: 'stranger@example.com', password}, {token: true});
    const wrong = await post('/sign-in', {email: 'asha@example.com', password: password + '!'}, {token: true});
    fails(unknown, 'wrongEmailOrPassword', 'unknown email');
    fails(wrong, 'wrongEmailOrPassword', 'wrong password');
    eq(unknown.text, wrong.text, 'unknown email and wrong password have identical bodies');
    const headerSet = r => [...r.headers].filter(([key]) => key !== 'date');
    eq(headerSet(unknown), headerSet(wrong), 'and identical headers');
    const cookieWrong = await post('/sign-in', {email: 'asha@example.com', password: password + '!'}, {as: new Jar()});
    fails(cookieWrong, 'wrongEmailOrPassword', 'cookie-mode wrong password');
    eq((await post('/sign-up', {name: 'Bad', email: 'not-an-email', password}, {token: true})).status, 400, 'an invalid email is a 400');
    // Transports: bearer, cookie with CSRF, and their failures.
    const anonymousRsvp = await post('/parties/1/rsvp');
    eq([anonymousRsvp.status, anonymousRsvp.body], [401, {error: 'unauthorized'}], 'no credential: the post\'s unauthorized');
    eq((await post('/parties', party('x', 500), {as: 'A'.repeat(43)})).status, 401, 'an unknown bearer token is refused');
    eq((await post('/parties', party('x', 500), {as: dana, omit: ['x-csrf-token']})).status, 403, 'a cookie mutation without CSRF is refused');
    eq((await post('/parties', party('x', 500), {as: dana, headers: {origin: 'http://evil.example'}})).status, 403, 'a cookie mutation from another origin is refused');
    eq((await post('/parties', party('x', 500), {as: asha.token, headers: {cookie: dana.header()}})).status, 400, 'cookie and bearer together are a 400');
    eq(sql(database, 'SELECT count(*) FROM party')[0][0], 0, 'no refused request wrote a party');

    // ------------------------------------------------------------------------ hosting
    section = 'host';
    fails(await post('/parties', party('Yesterday', 60), {as: asha.token}), 'dateInPast', 'a date before the server clock');
    fails(await post('/parties', party('Now', 100), {as: asha.token}), 'dateInPast', 'a date equal to the server clock');
    const first = await post('/parties', party('Housewarming', 1000), {as: asha.token});
    eq([first.status, typeof first.body.ok], [200, 'number'], 'hosting replies with the party reference');
    const housewarming = first.body.ok;
    eq(sql(database, 'SELECT host, title, date, guestList FROM party WHERE id=?', [housewarming]),
      [[1, 'Housewarming', 1000, 'everyone']], 'the host is the signed-in person; the date is stored');
    eq((await post('/parties', party('Anon', 500))).status, 401, 'hosting needs a session');
    const danaParty = await post('/parties', party('Dana\'s', 2000, 'attendees'), {as: dana});
    eq(danaParty.status, 200, 'cookie-mode hosting with CSRF');
    eq((await post('/parties', {...party('Bad', 500), guestList: 'friends'}, {as: asha.token})).status, 400, 'an unknown visibility is a 400');
    eq((await post('/parties', {...party('Forged', 500), host: 2}, {as: asha.token})).status, 400, 'the host is not a body field');
    const page = await get(`/parties/${housewarming}`);
    eq(page.body, {ok: {title: 'Housewarming', description: 'About Housewarming', date: at(1000), guests: {tag: 'visible', value: {guests: []}}}}, 'the party page');

    // --------------------------------------------------------------------------- RSVP
    section = 'rsvp';
    ok(await post(`/parties/${housewarming}/rsvp`, undefined, {as: ben.token}), null, 'RSVP');
    ok(await post(`/parties/${housewarming}/rsvp`, undefined, {as: ben.token}), null, 'a second yes is fine');
    eq(sql(database, 'SELECT count(*) FROM rsvp WHERE party=? AND guest=?', [housewarming, ben.id])[0][0], 1, 'and stays one RSVP');
    ok(await post(`/parties/${housewarming}/rsvp`, undefined, {as: dana}), null, 'cookie-mode RSVP with CSRF');
    fails(await post('/parties/999/rsvp', undefined, {as: ben.token}), 'notFound', 'RSVP to a missing party');
    eq((await post('/parties/abc/rsvp', undefined, {as: ben.token})).status, 400, 'a non-reference path segment is a 400');
    eq((await post(`/parties/${housewarming}/rsvp`, {party: housewarming}, {as: ben.token})).status, 400, 'a path field in the body is refused');
    const cutoff = (await post('/parties', party('Cutoff', 500), {as: asha.token})).body.ok;
    await setClock(499);
    ok(await post(`/parties/${cutoff}/rsvp`, undefined, {as: cara.token}), null, 'RSVP a second before the start');
    await setClock(500);
    fails(await post(`/parties/${cutoff}/rsvp`, undefined, {as: ben.token}), 'alreadyStarted', 'RSVP at the start (server clock)');
    await setClock(501);
    fails(await post(`/parties/${cutoff}/rsvp`, undefined, {as: eve.token}), 'alreadyStarted', 'RSVP after the start');
    await setClock(100);
    eq(sql(database, 'SELECT guest FROM rsvp WHERE party=? ORDER BY guest', [cutoff]), [[cara.id]], 'only the RSVP before the cutoff is stored');

    // ------------------------------------------------------------- visibility × role
    section = 'matrix';
    const visibility = {};
    for (const v of ['everyone', 'attendees', 'hostOnly']) {
      visibility[v] = (await post('/parties', party(`Party ${v}`, 5000, v), {as: asha.token})).body.ok;
      ok(await post(`/parties/${visibility[v]}/rsvp`, undefined, {as: ben.token}), null, `Ben RSVPs to ${v}`);
    }
    const roles = {host: asha.token, attendee: ben.token, visitor: cara.token, anonymous: undefined};
    const sees = {everyone: ['host', 'attendee', 'visitor', 'anonymous'], attendees: ['host', 'attendee'], hostOnly: ['host']};
    for (const [v, id] of Object.entries(visibility)) {
      for (const [role, as] of Object.entries(roles)) {
        const result = await get(`/parties/${id}`, {as});
        eq(result.status, 200, `${v} × ${role}: status`);
        eq(Object.keys(result.body.ok).sort(), ['date', 'description', 'guests', 'title'], `${v} × ${role}: page fields`);
        if (sees[v].includes(role)) {
          eq(result.body.ok.guests, {tag: 'visible', value: {guests: [{name: 'Ben'}]}}, `${v} × ${role}: visible, names only`);
        } else {
          eq(result.body.ok.guests, 'hidden', `${v} × ${role}: hidden`);
          check(!result.text.includes('Ben') && !/"(count|guests)"\s*:\s*\[/.test(result.text) && !/\d+\s*(guests|going)/.test(result.text),
            `${v} × ${role}: a hidden response has no names and no count`);
        }
      }
    }
    // The host is the host even after RSVPing to their own party; cookie readers resolve too.
    ok(await post(`/parties/${visibility.hostOnly}/rsvp`, undefined, {as: asha.token}), null, 'the host RSVPs to their own party');
    const names = guests => guests.tag === 'visible' ? guests.value.guests.map(g => g.name).sort() : guests;
    eq(names((await get(`/parties/${visibility.hostOnly}`, {as: asha.token})).body.ok.guests), ['Asha', 'Ben'], 'and still sees the hostOnly list');
    eq((await get(`/parties/${visibility.attendees}`, {as: dana})).body.ok.guests, 'hidden', 'a cookie-mode visitor is a visitor');
    eq((await get(`/parties/${visibility.attendees}`, {as: 'A'.repeat(43)})).status, 401, 'a bad token is refused, not read as anonymous');
    fails(await get('/parties/999'), 'notFound', 'a missing party page');

    // ------------------------------------------------------------ edit (Party.Changes)
    section = 'edit';
    const editable = (await post('/parties', party('Picnic', 5000), {as: asha.token})).body.ok;
    ok(await post(`/parties/${editable}/rsvp`, undefined, {as: ben.token}), null, 'Ben RSVPs');
    ok(await post(`/parties/${editable}/edit`, {title: 'Garden party', description: 'Bring a chair', guestList: 'attendees'}, {as: asha.token}), null, 'the host edits');
    const edited = await get(`/parties/${editable}`, {as: asha.token});
    eq([edited.body.ok.title, edited.body.ok.description, edited.body.ok.date], ['Garden party', 'Bring a chair', at(5000)], 'title and description changed, date kept');
    eq((await get(`/parties/${editable}`, {as: cara.token})).body.ok.guests, 'hidden', 'the new visibility applies at once');
    const before = sql(database, 'SELECT host, date FROM party WHERE id=?', [editable]);
    eq((await post(`/parties/${editable}/edit`, {title: 'T', description: 'D', guestList: 'everyone', date: at(9000)}, {as: asha.token})).status, 400, 'an edit cannot carry a date');
    eq((await post(`/parties/${editable}/edit`, {title: 'T', description: 'D', guestList: 'everyone', host: cara.id}, {as: asha.token})).status, 400, 'an edit cannot carry a host');
    eq(sql(database, 'SELECT host, date, title FROM party WHERE id=?', [editable]), [[...before[0], 'Garden party']], 'host, date and title untouched by refused edits');
    fails(await post(`/parties/${editable}/edit`, {title: 'Mine', description: 'D', guestList: 'everyone'}, {as: ben.token}), 'notHost', 'an attendee cannot edit');
    fails(await post('/parties/999/edit', {title: 'T', description: 'D', guestList: 'everyone'}, {as: asha.token}), 'notFound', 'edit a missing party');
    eq((await post(`/parties/${editable}/edit`, {title: 'T', description: 'D', guestList: 'everyone'})).status, 401, 'edit needs a session');
    ok(await post(`/parties/${danaParty.body.ok}/edit`, {title: 'Dana\'s dinner', description: 'D', guestList: 'hostOnly'}, {as: dana}), null, 'cookie-mode edit with CSRF');

    // ----------------------------------------------------------------------- reschedule
    section = 'reschedule';
    const movable = (await post('/parties', party('Movable', 1000), {as: asha.token})).body.ok;
    fails(await post('/parties/999/reschedule', {date: at(3000)}, {as: asha.token}), 'notFound', 'notFound');
    fails(await post(`/parties/${movable}/reschedule`, {date: at(3000)}, {as: ben.token}), 'notHost', 'notHost');
    fails(await post(`/parties/${movable}/reschedule`, {date: at(50)}, {as: asha.token}), 'dateInPast', 'dateInPast (before now)');
    fails(await post(`/parties/${movable}/reschedule`, {date: at(100)}, {as: asha.token}), 'dateInPast', 'dateInPast (equal to now)');
    ok(await post(`/parties/${movable}/reschedule`, {date: at(2000)}, {as: asha.token}), null, 'the host reschedules');
    eq((await get(`/parties/${movable}`)).body.ok.date, at(2000), 'the new date is served');
    await setClock(2000);
    fails(await post(`/parties/${movable}/reschedule`, {date: at(3000)}, {as: asha.token}), 'alreadyStarted', 'alreadyStarted (server clock at the start)');
    fails(await post(`/parties/${movable}/reschedule`, {date: at(1500)}, {as: asha.token}), 'alreadyStarted', 'a started party reports alreadyStarted before dateInPast');
    fails(await post(`/parties/${movable}/reschedule`, {date: at(3000)}, {as: ben.token}), 'notHost', 'notHost is checked first');
    await setClock(100);
    eq(sql(database, 'SELECT date FROM party WHERE id=?', [movable]), [[2000]], 'refused reschedules change nothing');

    // ------------------------------------------------------------------- cancel cascade
    section = 'cancel';
    const doomed = (await post('/parties', party('Doomed', 5000), {as: asha.token})).body.ok;
    ok(await post(`/parties/${doomed}/rsvp`, undefined, {as: ben.token}), null, 'Ben RSVPs');
    ok(await post(`/parties/${doomed}/rsvp`, undefined, {as: cara.token}), null, 'Cara RSVPs');
    eq(sql(database, 'SELECT count(*) FROM rsvp WHERE party=?', [doomed])[0][0], 2, 'two RSVPs');
    const otherRsvps = sql(database, 'SELECT count(*) FROM rsvp WHERE party<>?', [doomed])[0][0];
    fails(await post(`/parties/${doomed}/cancel`, undefined, {as: ben.token}), 'notHost', 'a guest cannot cancel');
    eq((await post(`/parties/${doomed}/cancel`)).status, 401, 'cancel needs a session');
    ok(await post(`/parties/${doomed}/cancel`, undefined, {as: asha.token}), null, 'the host cancels');
    eq(sql(database, 'SELECT count(*) FROM party WHERE id=?', [doomed])[0][0], 0, 'the party is gone');
    eq(sql(database, 'SELECT count(*) FROM rsvp WHERE party=?', [doomed])[0][0], 0, 'its RSVPs are deleted with it (Rsvp.cancelWithParty)');
    eq(sql(database, 'SELECT count(*) FROM rsvp WHERE party<>?', [doomed])[0][0], otherRsvps, 'other parties keep their RSVPs');
    fails(await get(`/parties/${doomed}`), 'notFound', 'its page is notFound');
    fails(await post(`/parties/${doomed}/cancel`, undefined, {as: asha.token}), 'notFound', 'cancelling twice is notFound');
    fails(await post(`/parties/${doomed}/rsvp`, undefined, {as: ben.token}), 'notFound', 'RSVP to a cancelled party is notFound');

    // ------------------------------------------------------------- restart, persistence
    section = 'restart';
    await server.stop();
    server = await start('partiful', database);
    check(server.stop, 'restarts on its own database');
    check(!server.log().includes('migrated'), 'a current database needs no migration');
    eq(names((await get(`/parties/${housewarming}`, {as: ben.token})).body.ok.guests), ['Ben', 'Dana'], 'parties and RSVPs persist');
    ok(await post(`/parties/${housewarming}/rsvp`, undefined, {as: cara.token}), null, 'a bearer session survives a restart');
    ok(await post(`/parties/${housewarming}/rsvp`, undefined, {as: danaIn}), null, 'a cookie session survives a restart');
    eq((await post(`/parties/${housewarming}/rsvp`, undefined, {as: asha.token})).status, 200, 'the first token is still live (sessions are stored)');
    eq((await post('/sign-in', {email: 'ben@example.com', password}, {token: true})).status, 200, 'sign-in after restart');
    const check2 = command('partiful', database, 'migrate', '--check');
    eq(check2.status, 0, 'migrate --check on a current database');
    check(/current|up to date|nothing/i.test(check2.stdout + check2.stderr), 'reports nothing to do');
    // Read-only pages and API share paths: a navigation gets the page, a client the endpoint.
    const html = await fetch(`${origin}/parties/${housewarming}`, {headers: {accept: 'text/html'}});
    eq([html.status, (html.headers.get('content-type') ?? '').split(';')[0]], [200, 'text/html'], 'a navigation gets the HTML page');
    eq((await fetch(`${origin}/parties/${housewarming}`)).headers.get('content-type'), 'application/json', 'fetch gets the endpoint');
    for (const path of ['/sign-up', '/sign-in', '/parties/new']) {
      const shell = await fetch(origin + path, {headers: {accept: 'text/html'}});
      eq(shell.status, 200, `page ${path}`);
    }
    eq((await get('/nowhere')).body, {error: 'notFound'}, 'an unknown path is the envelope 404');
    await server.stop();
    server = null;
  }

  if (!only || only === 'migration') {
    // ------------------------------------------- migration gate on a real old database
    section = 'migration';
    const old = join(run, 'before.sqlite');
    const before = await start('leanapi_apps', old, ['partiful-before']);
    check(before.stop, 'Partiful before `guestList` serves');
    const ashaOld = (await post('/sign-up', {name: 'Asha', email: 'asha@example.com', password}, {token: true})).body.ok;
    const benOld = (await post('/sign-up', {name: 'Ben', email: 'ben@example.com', password}, {token: true})).body.ok;
    const oldParty = await post('/parties', {title: 'Housewarming', description: 'Bring a plant', date: at(1000)}, {as: ashaOld.token});
    eq(oldParty.body, {ok: 1}, 'an old party (no guestList)');
    ok(await post('/parties/1/rsvp', undefined, {as: benOld.token}), null, 'an old RSVP');
    eq((await get('/parties/1')).body.ok.guests, [{name: 'Ben'}], 'the old app shows every guest');
    await before.stop();
    eq(columns(old, 'party'), ['id', 'host', 'title', 'description', 'date'], 'the old party table has no guestList');
    const backup = join(run, 'before-copy.sqlite');
    await copyFile(old, backup);
    // Without the migration the gate refuses, names the field, and changes nothing.
    const refused = await start('partiful_unmigrated', old);
    eq(refused.exitCode, 3, 'the app without the migration refuses the old database (exit 3)');
    check(/Party\.guestList/.test(refused.log()), 'the refusal names Party.guestList');
    eq(columns(old, 'party'), ['id', 'host', 'title', 'description', 'date'], 'a refusal changes nothing');
    const refusedCheck = command('partiful_unmigrated', old, 'migrate', '--check');
    check(refusedCheck.status !== 0 && /Party\.guestList/.test(refusedCheck.stdout + refusedCheck.stderr), 'migrate --check without the migration refuses too');
    // With it: `migrate --check` reports, `migrate` backfills.
    const pending = command('partiful', old, 'migrate', '--check');
    eq(pending.status, 0, 'migrate --check with the migration');
    check(/pending/.test(pending.stdout) && /Party\.guestList := 'everyone'/.test(pending.stdout), 'reports the pending backfill');
    eq(columns(old, 'party').length, 5, 'migrate --check changes nothing');
    const migrated = command('partiful', old, 'migrate');
    eq(migrated.status, 0, 'migrate');
    check(/migrated/.test(migrated.stdout) && /addGuestList/.test(migrated.stdout), 'reports the applied migration by name');
    eq(columns(old, 'party'), ['id', 'host', 'title', 'description', 'date', 'guestList'], 'the party table gains guestList');
    eq(sql(old, 'SELECT id, guestList FROM party'), [[1, 'everyone']], 'existing parties are backfilled with everyone');
    eq(sql(old, 'SELECT name FROM _leandb_applied_migrations'), [['addGuestList']], 'the migration is recorded by name');
    const served = await start('partiful', old);
    check(served.stop, 'the migrated database serves');
    const ashaNew = (await post('/sign-in', {email: 'asha@example.com', password}, {token: true})).body.ok;
    eq(ashaNew.profile, 1, 'an old account signs in (its credential carried over)');
    eq((await get('/parties/1')).body.ok.guests, {tag: 'visible', value: {guests: [{name: 'Ben'}]}}, 'an old party behaves as before (everyone)');
    ok(await post('/parties/1/edit', {title: 'Housewarming', description: 'Bring a plant', guestList: 'hostOnly'}, {as: ashaNew.token}), null, 'the old party can now be made private');
    eq((await get('/parties/1')).body.ok.guests, 'hidden', 'and is');
    ok(await post('/parties/1/rsvp', undefined, {as: benOld.token}), null, 'an old session still works after the migration');
    await served.stop();
    // The startup gate applies the same backfill without the command.
    const startup = await start('partiful', backup);
    check(startup.stop && /migrated/.test(startup.log()) && /addGuestList/.test(startup.log()), 'startup applies the declared migration and reports it');
    eq(sql(backup, 'SELECT guestList FROM party'), [['everyone']], 'and backfills');
    await startup.stop();
  }

  if (!only || only === 'browser') {
    // ------------------------------------------------------------- Chromium, real App
    section = 'browser';
    await setClock(100);
    server = await start('partiful', database);
    check(server.stop, 'partiful serves');
    const {chromium} = await import(pathToFileURL(join(nodeModules, 'playwright-core/index.mjs')));
    browser = await chromium.launch({headless: true});
    const errors = [];
    const context = async () => {
      const c = await browser.newContext();
      const page = await c.newPage();
      page.on('pageerror', error => errors.push(error.message));
      return {context: c, page};
    };
    const alice = await context(), bob = await context();
    const main = page => page.locator('main');
    async function signUp(page, name, email) {
      await page.goto(origin + '/sign-up');
      await page.locator('input[name=name]').fill(name);
      await page.locator('input[name=email]').fill(email);
      await page.locator('input[name=password]').fill(password);
      await page.locator('button[type=submit]').click();
    }
    await signUp(alice.page, 'Browser Alice', 'browser-alice@example.com');
    await alice.page.waitForURL(origin + '/');
    eq(new URL(alice.page.url()).pathname, '/', 'sign-up navigates to "/" (the post\'s onSuccess)');
    const aliceCookies = await alice.context.cookies();
    check(aliceCookies.some(c => c.name === 'leanapp_session' && c.httpOnly), 'the browser holds an HttpOnly session cookie');
    check(aliceCookies.some(c => c.name === 'leanapp_csrf' && !c.httpOnly), 'and a readable CSRF cookie');
    // The emailTaken field error, in another browser.
    const dup = await context();
    await signUp(dup.page, 'Copycat', 'browser-alice@example.com');
    await main(dup.page).getByText('This email already has an account. Sign in instead?').waitFor();
    check(true, 'sign-up shows the emailTaken field error');
    eq(new URL(dup.page.url()).pathname, '/sign-up', 'and stays on the page');
    eq((await dup.context.cookies()).length, 0, 'a refused sign-up sets no cookies');
    eq(await dup.page.locator('input[name=email]').inputValue(), 'browser-alice@example.com', 'the draft is kept');
    // Host a party from the form.
    await alice.page.goto(origin + '/parties/new');
    const fields = await alice.page.locator('form [name]').evaluateAll(nodes => nodes.map(node => node.getAttribute('name')));
    eq(fields, ['title', 'description', 'date', 'guestList'], 'the host form has one editor per body field');
    await alice.page.locator('[name=title]').fill('Browser dinner');
    await alice.page.locator('[name=description]').fill('Together');
    // `Time` is a UTC datetime-local editor (seconds step).
    await alice.page.locator('[name=date]').fill(at(5000).replace('Z', ''));
    await alice.page.locator('[name=guestList]').selectOption('attendees');
    await alice.page.locator('button[type=submit]').click();
    await alice.page.waitForURL(/\/parties\/\d+$/);
    const partyURL = alice.page.url();
    const partyId = Number(partyURL.split('/').pop());
    eq(sql(database, 'SELECT title, guestList, date FROM party WHERE id=?', [partyId]), [['Browser dinner', 'attendees', 5000]], 'the form hosted the party');
    await main(alice.page).getByRole('heading', {name: 'Browser dinner'}).waitFor();
    check(true, 'the party page loads after navigation');
    // Bob signs up in his own browser and RSVPs with the `call` button.
    await signUp(bob.page, 'Browser Bob', 'browser-bob@example.com');
    await bob.page.waitForURL(origin + '/');
    await bob.page.goto(partyURL);
    await main(bob.page).getByText('The host is keeping the guest list private.').waitFor();
    check(!(await main(bob.page).innerText()).includes('Browser Bob'), 'before RSVPing, an attendees-only list is hidden');
    await bob.page.getByRole('button', {name: "I'm going", exact: true}).click();
    await main(bob.page).getByText('Browser Bob', {exact: true}).waitFor();
    check(true, 'the RSVP call reloads the page data: Bob now sees the list');
    await bob.page.getByRole('button', {name: "I'm going", exact: true}).click();
    await pause(300);
    eq(await main(bob.page).getByText('Browser Bob', {exact: true}).count(), 1, 'a second yes still lists Bob once');
    eq(sql(database, 'SELECT count(*) FROM rsvp WHERE party=?', [partyId])[0][0], 1, 'and stores one RSVP');
    // Reload: the actor and CSRF come back from the bootstrap and cookie.
    await bob.page.reload();
    await main(bob.page).getByText('Browser Bob', {exact: true}).waitFor();
    const [afterReload] = await Promise.all([
      bob.page.waitForResponse(response => response.url().endsWith(`/parties/${partyId}/rsvp`)),
      bob.page.getByRole('button', {name: "I'm going", exact: true}).click()]);
    eq(afterReload.status(), 200, 'a mutation after reload carries CSRF');
    eq(afterReload.request().headers()['x-csrf-token'], (await bob.context.cookies()).find(c => c.name === 'leanapp_csrf').value,
      'read from the CSRF cookie at send time');
    // Visible and hidden rendering: Alice's edit form makes the list host-only.
    const editForm = alice.page.locator('form').filter({has: alice.page.locator('[name=guestList]')});
    await editForm.locator('[name=title]').fill('Browser dinner');
    await editForm.locator('[name=description]').fill('Together');
    await editForm.locator('[name=guestList]').selectOption('hostOnly');
    await editForm.locator('button[type=submit]').click();
    await main(alice.page).getByText('Browser Bob', {exact: true}).waitFor();
    check(true, 'the host still sees the hostOnly list');
    await bob.page.reload();
    await main(bob.page).getByText('The host is keeping the guest list private.').waitFor();
    check(!(await main(bob.page).innerText()).includes('Browser Bob'), 'Bob sees the hidden rendering, with no names');
    // A non-host's cancel is refused with the authored notice.
    await bob.page.getByRole('button', {name: 'Cancel party', exact: true}).click();
    await main(bob.page).getByText('Only the host can cancel this party.').waitFor();
    check(true, 'a domain error from `call` shows its notice');
    // Logout invalidation: the session cookies go away; the page drops Bob's view at once.
    await editForm.locator('[name=title]').fill('Browser dinner');
    await editForm.locator('[name=description]').fill('Together');
    await editForm.locator('[name=guestList]').selectOption('attendees');
    await Promise.all([alice.page.waitForResponse(response => response.url().endsWith(`/parties/${partyId}/edit`)),
      editForm.locator('button[type=submit]').click()]);
    eq(sql(database, 'SELECT guestList FROM party WHERE id=?', [partyId]), [['attendees']], 'the edit form changed the visibility');
    await bob.page.reload();
    await main(bob.page).getByText('Browser Bob', {exact: true}).waitFor();
    await bob.context.clearCookies();
    await main(bob.page).getByText('The host is keeping the guest list private.').waitFor({timeout: 5000});
    check(!(await main(bob.page).innerText()).includes('Browser Bob'), 'signing out drops the attendee view without a reload');
    await bob.page.getByRole('button', {name: "I'm going", exact: true}).click();
    await bob.page.getByRole('alert').filter({hasText: 'Please sign in.'}).waitFor();
    check(true, 'a signed-out call reports the framework failure');
    // Sign back in from the page.
    await bob.page.goto(origin + '/sign-in');
    await bob.page.locator('input[name=email]').fill('browser-bob@example.com');
    await bob.page.locator('input[name=password]').fill(password + '!');
    await bob.page.locator('button[type=submit]').click();
    await main(bob.page).getByText('Wrong email or password.').waitFor();
    check(true, 'sign-in shows its notice');
    await bob.page.locator('input[name=password]').fill(password);
    await bob.page.locator('button[type=submit]').click();
    await bob.page.waitForURL(origin + '/');
    await bob.page.goto(partyURL);
    await main(bob.page).getByText('Browser Bob', {exact: true}).waitFor();
    check(true, 'signed in again, Bob sees the list');
    // The host cancels from the page.
    await alice.page.getByRole('button', {name: 'Cancel party', exact: true}).click();
    await alice.page.waitForURL(origin + '/parties/new');
    eq(sql(database, 'SELECT count(*) FROM rsvp WHERE party=?', [partyId])[0][0], 0, 'cancelling from the page cascades');
    eq(errors, [], 'no page errors');
  }
  report();
} finally {
  if (browser) await browser.close();
  if (server?.stop) await server.stop();
}
