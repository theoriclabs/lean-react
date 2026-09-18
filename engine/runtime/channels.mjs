/** One multiplexed WebSocket per origin. Frames follow LeanContract.Channel. */

const backoff = attempt => Math.min(30000, 1000 * 2 ** Math.min(attempt, 5)) + Math.floor(Math.random() * 250);

export function encodeFrame(frame) {
  return JSON.stringify(frame);
}

export function decodeFrame(text) {
  const value = typeof text === 'string' ? JSON.parse(text) : text;
  if (!value || typeof value.tag !== 'string') throw new TypeError('channel frame missing tag');
  return value;
}

export function createChannelRuntime({
  WebSocketImpl = globalThis.WebSocket,
  csrf = () => '',
  origin = typeof location !== 'undefined' ? location.origin : 'http://127.0.0.1',
  path = '/ws',
  protocol = 'leanapp.v1',
  hiddenCloseMs = 60000,
} = {}) {
  let socket = null;
  let attempt = 0;
  let generation = 0;
  const subscriptions = new Map();
  let reconnectTimer = null;

  function send(frame) {
    if (!socket || socket.readyState !== 1) return false;
    socket.send(encodeFrame(frame));
    return true;
  }

  function hello() {
    send({ tag: 'hello', protocol: 1, csrf: csrf() });
  }

  function resubscribeAll() {
    for (const sub of subscriptions.values()) {
      sub.generation += 1;
      send({
        tag: 'subscribe',
        sub: sub.id,
        channel: sub.channel,
        params: sub.params,
        resume: sub.resume ?? null,
      });
    }
  }

  function open() {
    if (socket || !WebSocketImpl) return;
    const url = path.startsWith('ws') ? path : `${origin.replace(/^http/, 'ws')}${path}`;
    socket = new WebSocketImpl(url, protocol);
    socket.addEventListener('open', () => {
      attempt = 0;
      hello();
      resubscribeAll();
    });
    socket.addEventListener('message', event => {
      let frame;
      try { frame = decodeFrame(event.data); } catch { return; }
      if (frame.tag === 'event') {
        const sub = [...subscriptions.values()].find(s => s.id === frame.sub);
        if (!sub) return;
        if (sub.lastSeq != null && frame.seq !== sub.lastSeq + 1) {
          send({ tag: 'subscribe', sub: sub.id, channel: sub.channel, params: sub.params, resume: sub.resume ?? null });
          return;
        }
        sub.lastSeq = frame.seq;
        sub.onEvent?.(frame.seq, frame.payload);
      } else if (frame.tag === 'subscribed') {
        const sub = [...subscriptions.values()].find(s => s.id === frame.sub);
        if (sub?.onSnapshot && frame.snapshot != null) sub.onSnapshot(frame.snapshot);
      } else if (frame.tag === 'fail') {
        const sub = [...subscriptions.values()].find(s => s.id === frame.sub);
        if (sub) sub.onDenied?.(frame.error);
      } else if (frame.tag === 'ack' || frame.tag === 'fail') {
        const sub = [...subscriptions.values()].find(s => s.id === frame.sub);
        sub?.pending.get(frame.msgId)?.(frame);
      }
    });
    socket.addEventListener('close', () => {
      socket = null;
      attempt += 1;
      for (const sub of subscriptions.values()) sub.onOffline?.(attempt);
      reconnectTimer = setTimeout(open, backoff(attempt));
    });
  }

  if (typeof document !== 'undefined') {
    document.addEventListener('visibilitychange', () => {
      if (document.hidden) {
        setTimeout(() => { if (document.hidden && socket) socket.close(); }, hiddenCloseMs);
      } else if (!socket) open();
    });
  }

  let nextSub = 1;
  let nextMsg = 1;

  return {
    use({ channel, params, resume, onEvent, onSnapshot, onDenied, onOffline, enabled = true }) {
      const id = nextSub++;
      const record = { id, channel, params, resume, onEvent, onSnapshot, onDenied, onOffline, lastSeq: null, generation: 0, pending: new Map() };
      if (enabled) {
        subscriptions.set(id, record);
        open();
        if (socket?.readyState === 1) {
          send({ tag: 'subscribe', sub: id, channel, params, resume: resume ?? null });
        }
      }
      return {
        id,
        send(payload, timeoutMs = 10000) {
          return new Promise((resolve, reject) => {
            const msgId = nextMsg++;
            const timer = setTimeout(() => {
              record.pending.delete(msgId);
              reject(Object.assign(new Error('timeout'), { code: 'timeout' }));
            }, timeoutMs);
            record.pending.set(msgId, frame => {
              clearTimeout(timer);
              record.pending.delete(msgId);
              if (frame.tag === 'ack') resolve(frame.payload);
              else reject(frame.error);
            });
            if (!send({ tag: 'send', sub: id, msgId, payload })) {
              clearTimeout(timer);
              record.pending.delete(msgId);
              reject(Object.assign(new Error('disconnected'), { code: 'disconnected' }));
            }
          });
        },
        resubscribe() {
          send({ tag: 'subscribe', sub: id, channel, params, resume: record.resume ?? null });
        },
        close() {
          subscriptions.delete(id);
          send({ tag: 'unsubscribe', sub: id });
        },
        setResume(value) { record.resume = value; },
        get generation() { return generation; },
      };
    },
    _open: open,
    _socket() { return socket; },
    _subscriptions() { return subscriptions; },
  };
}
