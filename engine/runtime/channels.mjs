/** One multiplexed WebSocket per origin. Frames follow LeanContract.Channel. */

const defaults = {
  base: 1000,
  cap: 30000,
  goingAwaySpreadMs: 10000,
};

/** Full-jitter delay. Ordinary drops use `random(0, min(cap, base · 2^attempt))`.
 *  After a `1001` close or a failed upgrade (`503`), the first wait is
 *  `random(0, goingAwaySpreadMs)` (3× that while the tab is hidden). */
export function reconnectPolicy({
  attempt = 0,
  reason = 0,
  hidden = false,
  random = Math.random,
  base = defaults.base,
  cap = defaults.cap,
  goingAwaySpreadMs = defaults.goingAwaySpreadMs,
} = {}) {
  const goingAway = reason === 1001 || reason === 503;
  if (attempt === 0 && goingAway) {
    const spread = hidden ? goingAwaySpreadMs * 3 : goingAwaySpreadMs;
    return Math.floor(random() * Math.max(0, spread));
  }
  const max = Math.min(cap, base * 2 ** Math.min(Math.max(attempt, 0), 30));
  return Math.floor(random() * (max + 1));
}

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
  reconnectPolicy: policy = {},
  random = policy.random ?? Math.random,
  setTimeoutFn = globalThis.setTimeout,
  clearTimeoutFn = globalThis.clearTimeout,
} = {}) {
  const reconnect = { ...defaults, ...policy };
  let socket = null;
  let attempt = 0;
  let generation = 0;
  let opened = false;
  const subscriptions = new Map();
  let reconnectTimer = null;
  const hidden = () => typeof document !== 'undefined' && document.hidden;

  function send(frame) {
    if (!socket || socket.readyState !== 1) return false;
    socket.send(encodeFrame(frame));
    return true;
  }

  function hello() {
    send({ tag: 'hello', protocol: 1, csrf: csrf() });
  }

  function subscribeFrame(sub) {
    return {
      tag: 'subscribe',
      sub: sub.id,
      channel: sub.channel,
      params: sub.params,
      resume: sub.resume ?? null,
    };
  }

  function sendSubscribe(sub) {
    sub.generation += 1;
    send(subscribeFrame(sub));
  }

  function backgroundDelay() {
    return 1000 + Math.floor(random() * 2000);
  }

  /** Resubscribe in mount order; `priority: 'background'` waits 1–3 s. */
  function resubscribeAll() {
    const background = [];
    for (const sub of subscriptions.values()) {
      if (sub.priority === 'background') background.push(sub);
      else sendSubscribe(sub);
    }
    for (const sub of background) {
      setTimeoutFn(() => {
        if (subscriptions.has(sub.id) && socket?.readyState === 1) sendSubscribe(sub);
      }, backgroundDelay());
    }
  }

  function scheduleReconnect(reason) {
    if (reconnectTimer != null) clearTimeoutFn(reconnectTimer);
    const delay = reconnectPolicy({
      attempt,
      reason,
      hidden: hidden(),
      random,
      base: reconnect.base,
      cap: reconnect.cap,
      goingAwaySpreadMs: reconnect.goingAwaySpreadMs,
    });
    attempt += 1;
    reconnectTimer = setTimeoutFn(open, delay);
    return delay;
  }

  function open() {
    if (socket || !WebSocketImpl) return;
    const url = path.startsWith('ws') ? path : `${origin.replace(/^http/, 'ws')}${path}`;
    socket = new WebSocketImpl(url, protocol);
    socket.addEventListener('open', () => {
      attempt = 0;
      opened = true;
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
          send(subscribeFrame(sub));
          return;
        }
        sub.lastSeq = frame.seq;
        sub.onEvent?.(frame.seq, frame.payload);
      } else if (frame.tag === 'subscribed') {
        const sub = [...subscriptions.values()].find(s => s.id === frame.sub);
        if (sub?.onSnapshot && frame.snapshot != null) sub.onSnapshot(frame.snapshot);
      } else if (frame.tag === 'fail') {
        const sub = [...subscriptions.values()].find(s => s.id === frame.sub);
        if (sub) {
          if (frame.msgId != null) sub.pending.get(frame.msgId)?.(frame);
          else sub.onDenied?.(frame.error);
        }
      } else if (frame.tag === 'ack') {
        const sub = [...subscriptions.values()].find(s => s.id === frame.sub);
        sub?.pending.get(frame.msgId)?.(frame);
      }
    });
    socket.addEventListener('close', event => {
      socket = null;
      const reason = opened ? (event?.code ?? 0) : 503;
      opened = false;
      for (const sub of subscriptions.values()) sub.onOffline?.(attempt + 1);
      scheduleReconnect(reason);
    });
  }

  if (typeof document !== 'undefined') {
    document.addEventListener('visibilitychange', () => {
      if (document.hidden) {
        setTimeoutFn(() => { if (document.hidden && socket) socket.close(); }, hiddenCloseMs);
      } else if (!socket) open();
    });
  }

  let nextSub = 1;
  let nextMsg = 1;

  return {
    use({ channel, params, resume, onEvent, onSnapshot, onDenied, onOffline, enabled = true, priority = 'live' }) {
      const id = nextSub++;
      const record = {
        id, channel, params, resume, onEvent, onSnapshot, onDenied, onOffline,
        lastSeq: null, generation: 0, pending: new Map(), priority,
      };
      if (enabled) {
        subscriptions.set(id, record);
        open();
        if (socket?.readyState === 1) send(subscribeFrame(record));
      }
      return {
        id,
        send(payload, timeoutMs = 10000) {
          return new Promise((resolve, reject) => {
            const msgId = nextMsg++;
            const timer = setTimeoutFn(() => {
              record.pending.delete(msgId);
              reject(Object.assign(new Error('timeout'), { code: 'timeout' }));
            }, timeoutMs);
            record.pending.set(msgId, frame => {
              clearTimeoutFn(timer);
              record.pending.delete(msgId);
              if (frame.tag === 'ack') resolve(frame.payload);
              else reject(frame.error);
            });
            if (!send({ tag: 'send', sub: id, msgId, payload })) {
              clearTimeoutFn(timer);
              record.pending.delete(msgId);
              reject(Object.assign(new Error('disconnected'), { code: 'disconnected' }));
            }
          });
        },
        resubscribe() {
          send(subscribeFrame(record));
        },
        close() {
          subscriptions.delete(id);
          send({ tag: 'unsubscribe', sub: id });
        },
        setResume(value) { record.resume = value; },
        get generation() { return generation; },
      };
    },
    reconnectPolicy: reconnect,
    _open: open,
    _scheduleReconnect: scheduleReconnect,
    _socket() { return socket; },
    _subscriptions() { return subscriptions; },
  };
}
