// In-memory counters for the gateway's own behaviour, rendered in Prometheus text format. Reset on restart.
import { monitorEventLoopDelay } from 'node:perf_hooks';

const escape = value => String(value).replace(/["\\\n]/g, c => ({ '"': '\\"', '\\': '\\\\', '\n': '\\n' })[c]);
const labelText = labels => {
  const keys = Object.keys(labels).sort();
  return keys.length ? `{${keys.map(k => `${k}="${escape(labels[k])}"`).join(',')}}` : '';
};

export function createMetrics(prefix = 'leanapp_gateway') {
  const families = [];
  const family = (name, type, help) => { const f = { name: `${prefix}_${name}`, type, help, series: new Map(), gauge: null }; families.push(f); return f; };
  const lag = monitorEventLoopDelay({ resolution: 20 });
  lag.enable();
  const metrics = {
    /** Monotonic counter; `inc(labels?, by?)`. Series appear on first increment. */
    counter(name, help) {
      const f = family(name, 'counter', help);
      return { inc: (labels = {}, by = 1) => { const key = labelText(labels); f.series.set(key, (f.series.get(key) ?? 0) + by); } };
    },
    /** Gauge read at scrape time from `read()`, which returns a number or `[[labels, value], …]`. */
    gauge(name, help, read) { family(name, 'gauge', help).gauge = read; },
    /** Prometheus text exposition. Event-loop lag quantiles cover the interval since the previous scrape. */
    render() {
      const lines = [];
      for (const f of families) {
        lines.push(`# HELP ${f.name} ${f.help}`, `# TYPE ${f.name} ${f.type}`);
        if (f.gauge) {
          const value = f.gauge();
          for (const [labels, v] of Array.isArray(value) ? value : [[{}, value]]) lines.push(`${f.name}${labelText(labels)} ${v}`);
        } else if (f.series.size === 0) lines.push(`${f.name} 0`);
        else for (const [labels, v] of f.series) lines.push(`${f.name}${labels} ${v}`);
      }
      const ms = n => (n / 1e6).toFixed(3);
      lines.push(`# HELP ${prefix}_event_loop_lag_ms Event loop delay since the previous scrape`, `# TYPE ${prefix}_event_loop_lag_ms gauge`,
        `${prefix}_event_loop_lag_ms{quantile="0.5"} ${ms(lag.percentile(50))}`, `${prefix}_event_loop_lag_ms{quantile="0.99"} ${ms(lag.percentile(99))}`,
        `${prefix}_event_loop_lag_ms{quantile="max"} ${ms(lag.max)}`);
      lag.reset();
      return lines.join('\n') + '\n';
    },
    close() { lag.disable(); },
  };
  return metrics;
}

/** `/internal/*` is served only to loopback peers and never proxied. */
export const isLoopback = address => ['127.0.0.1', '::1', '::ffff:127.0.0.1'].includes(address);
