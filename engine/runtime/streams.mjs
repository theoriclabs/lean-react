/** One-way SSE/EventSource connector sharing reconnect/ownership rules with channels.mjs. */

const backoff = attempt => Math.min(30000, 1000 * 2 ** Math.min(attempt, 5)) + Math.floor(Math.random() * 250);

export function createStreamRuntime({ EventSourceImpl = globalThis.EventSource } = {}) {
  return {
    open({ url, lastEventId, onEvent, onState, enabled = true }) {
      let source = null;
      let attempt = 0;
      let closed = false;
      let timer = null;
      function connect() {
        if (closed || !enabled || !EventSourceImpl) return;
        onState?.({ status: attempt === 0 ? 'connecting' : 'reconnecting', attempt });
        const target = lastEventId ? `${url}${url.includes('?') ? '&' : '?'}lastEventId=${encodeURIComponent(lastEventId)}` : url;
        source = new EventSourceImpl(target);
        source.onopen = () => { attempt = 0; onState?.({ status: 'open' }); };
        source.onmessage = event => {
          lastEventId = event.lastEventId || lastEventId;
          onEvent?.({ id: event.lastEventId || null, event: event.data });
        };
        source.onerror = () => {
          source?.close();
          source = null;
          attempt += 1;
          onState?.({ status: 'reconnecting', attempt, lastError: 'transport' });
          timer = setTimeout(connect, backoff(attempt));
        };
      }
      connect();
      return {
        close() {
          closed = true;
          clearTimeout(timer);
          source?.close();
          source = null;
          onState?.({ status: 'closed', reason: 'user' });
        },
        reconnect() { attempt = 0; connect(); },
      };
    },
  };
}
