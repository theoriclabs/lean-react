/** One-way SSE/EventSource connector sharing reconnect/ownership rules with channels.mjs. */

import { reconnectPolicy } from './channels.mjs';

export { reconnectPolicy };

export function createStreamRuntime({
  EventSourceImpl = globalThis.EventSource,
  reconnectPolicy: policy = {},
  random = policy.random ?? Math.random,
  setTimeoutFn = globalThis.setTimeout,
  clearTimeoutFn = globalThis.clearTimeout,
} = {}) {
  const reconnect = {
    base: 1000,
    cap: 30000,
    goingAwaySpreadMs: 10000,
    ...policy,
  };
  return {
    reconnectPolicy: reconnect,
    open({ url, lastEventId, onEvent, onState, enabled = true }) {
      let source = null;
      let attempt = 0;
      let opened = false;
      let closed = false;
      let timer = null;
      function connect() {
        if (closed || !enabled || !EventSourceImpl) return;
        onState?.({ status: attempt === 0 ? 'connecting' : 'reconnecting', attempt });
        const target = lastEventId ? `${url}${url.includes('?') ? '&' : '?'}lastEventId=${encodeURIComponent(lastEventId)}` : url;
        source = new EventSourceImpl(target);
        source.onopen = () => { attempt = 0; opened = true; onState?.({ status: 'open' }); };
        source.onmessage = event => {
          lastEventId = event.lastEventId || lastEventId;
          onEvent?.({ id: event.lastEventId || null, event: event.data });
        };
        source.onerror = () => {
          const reason = opened ? 0 : 503;
          opened = false;
          source?.close();
          source = null;
          onState?.({ status: 'reconnecting', attempt: attempt + 1, lastError: 'transport' });
          const delay = reconnectPolicy({
            attempt,
            reason,
            hidden: typeof document !== 'undefined' && document.hidden,
            random,
            base: reconnect.base,
            cap: reconnect.cap,
            goingAwaySpreadMs: reconnect.goingAwaySpreadMs,
          });
          attempt += 1;
          timer = setTimeoutFn(connect, delay);
        };
      }
      connect();
      return {
        close() {
          closed = true;
          clearTimeoutFn(timer);
          source?.close();
          source = null;
          onState?.({ status: 'closed', reason: 'user' });
        },
        reconnect() { attempt = 0; connect(); },
      };
    },
  };
}
