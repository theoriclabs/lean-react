// Opt-in load check for the SSE hub: N idle streams plus a publish rate through the proxied path, with the
// gateway's own event-loop lag read from /internal/metrics. Run: node tests/gateway/load-events.mjs
// Knobs: STREAMS=2000 TOPICS=200 RATE=500 SECONDS=10 PER_COOKIE=8
import { spawn } from 'node:child_process';
import { request, Agent } from 'node:http';
import { randomBytes } from 'node:crypto';
import { startStub, freePort, operation } from './stub.mjs';

const STREAMS = Number(process.env.STREAMS ?? 2000), TOPICS = Number(process.env.TOPICS ?? 200), RATE = Number(process.env.RATE ?? 500);
const SECONDS = Number(process.env.SECONDS ?? 10), PER_COOKIE = Number(process.env.PER_COOKIE ?? 8);
const json = { 'x-leanapp-request': '1', 'content-type': 'application/json' };

const manifest = { operations: [
  operation('/api/doc/submit', { metadata: { publish: { topicField: 'doc', topicPrefix: 'doc', eventName: 'ops', alsoToActorField: null } } }),
  operation('/api/stream/open', { metadata: { issuesStreamTicket: true } }),
] };
const stub = await startStub({ manifest, replies: {
  '/api/stream/open': body => ({ body: { tag: 'success', value: { ticket: randomBytes(24).toString('base64url'), expiresAt: Date.now() + 3600000, topics: JSON.parse(body).topics } } }),
  '/api/doc/submit': body => ({ body: { tag: 'success', value: JSON.parse(body) } }),
} });
const port = await freePort(), origin = `http://127.0.0.1:${port}`;
const child = spawn(process.execPath, ['tests/gateway/run.mjs'], { stdio: ['ignore', 'inherit', 'inherit'], env: { ...process.env,
  GATEWAY_CONFIG: JSON.stringify({ port, origin, development: true, log: 'silent', drainMs: 2000,
    backend: { attach: { url: stub.url } }, limits: { maxConnections: STREAMS + 512, inFlight: 512 }, events: { maxStreams: STREAMS, maxStreamsPerCookie: PER_COOKIE } }) } });
for (let n = 0; n < 200; n++) { try { if ((await fetch(origin + '/health/ready')).ok) break; } catch {} await new Promise(r => setTimeout(r, 50)); }
const metrics = async () => Object.fromEntries([...(await (await fetch(origin + '/internal/metrics')).text()).matchAll(/^(leanapp_gateway_\S+) (\S+)$/gm)].map(m => [m[1], Number(m[2])]));

const agent = new Agent({ keepAlive: false, maxSockets: Infinity });
const received = new Uint32Array(STREAMS); let hellos = 0, closed = 0;
const open = i => new Promise((done, fail) => {
  const cookie = `leanapp_session=${randomBytes(8).toString('hex')}-${Math.floor(i / PER_COOKIE)}`;
  fetch(`${origin}/api/stream/open`, { method: 'POST', headers: { ...json, origin, cookie }, body: JSON.stringify({ topics: [`doc:${i % TOPICS}`] }) })
    .then(r => r.json()).then(({ value }) => {
      const req = request(`${origin}/stream?ticket=${value.ticket}`, { agent, headers: { accept: 'text/event-stream', cookie } }, res => {
        if (res.statusCode !== 200) return fail(new Error(`stream ${i}: ${res.statusCode}`));
        let buffer = '';
        res.on('data', chunk => { buffer += chunk; let at; while ((at = buffer.indexOf('\n\n')) >= 0) { const frame = buffer.slice(0, at); buffer = buffer.slice(at + 2);
          if (frame.includes('event: hello')) { hellos++; done(); } else if (frame.includes('event: ops')) received[i]++; } });
        res.on('close', () => closed++);
      });
      req.on('error', fail); req.end();
    }).catch(fail);
});
const t0 = performance.now();
for (let i = 0; i < STREAMS; i += 100) await Promise.all(Array.from({ length: Math.min(100, STREAMS - i) }, (_, k) => open(i + k)));
const openMs = Math.round(performance.now() - t0);
const idle = await metrics();
await new Promise(r => setTimeout(r, 1000));
await metrics(); // reset the lag window before the publish phase

let sent = 0, ok = 0, throttled = 0, failed = 0, topic = 0; const t1 = performance.now();
const publisher = setInterval(() => {
  const due = Math.floor((performance.now() - t1) * RATE / 1000) - sent;
  for (let k = 0; k < due; k++) {
    sent++; const doc = topic++ % TOPICS;
    fetch(`${origin}/api/doc/submit`, { method: 'POST', headers: { ...json, origin }, body: JSON.stringify({ doc: String(doc), n: sent }) })
      .then(r => { r.status === 200 ? ok++ : r.status === 429 ? throttled++ : failed++; return r.arrayBuffer(); }).catch(() => failed++);
  }
}, 10);
await new Promise(r => setTimeout(r, SECONDS * 1000));
clearInterval(publisher);
await new Promise(r => setTimeout(r, 500));
const after = await metrics(), publishMs = Math.round(performance.now() - t1);
const delivered = received.reduce((a, b) => a + b, 0);
const perTopic = Math.floor(STREAMS / TOPICS);
console.log(JSON.stringify({
  streams: { requested: STREAMS, hellos, closedDuringRun: closed, openMs, gaugeAfter: after['leanapp_gateway_streams'] },
  publish: { rate: RATE, seconds: SECONDS, sent, ok, throttled, failed, publishMs, achievedPerSecond: Math.round(ok / (publishMs / 1000)) },
  deliveries: { expected: ok * perTopic, receivedByClients: delivered, gatewayCounter: after['leanapp_gateway_stream_deliveries_total'], dropped: after['leanapp_gateway_stream_dropped_total'] },
  eventLoopLagMs: { idle: { p50: idle['leanapp_gateway_event_loop_lag_ms{quantile="0.5"}'], max: idle['leanapp_gateway_event_loop_lag_ms{quantile="max"}'] },
    publishing: { p50: after['leanapp_gateway_event_loop_lag_ms{quantile="0.5"}'], p99: after['leanapp_gateway_event_loop_lag_ms{quantile="0.99"}'], max: after['leanapp_gateway_event_loop_lag_ms{quantile="max"}'] } },
  memoryRssMb: Math.round(process.memoryUsage().rss / 1048576),
}, null, 2));
child.kill('SIGTERM'); await new Promise(r => child.on('exit', r));
agent.destroy(); await stub.close();
process.exit(after['leanapp_gateway_event_loop_lag_ms{quantile="max"}'] < 50 && failed === 0 ? 0 : 1);
