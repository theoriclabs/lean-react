import * as React from 'react';
import { registerForeign, ctor } from '../../engine/adapters/leanjs-react.mjs';

// A canvas that draws many intervals: one pass over the arrays, one rectangle per pixel column
// touched. The Lean side keeps the data and maps clicks back to intervals.
function TimelineCanvas({ width, height, ref }) {
  const canvas = React.useRef(null);
  React.useImperativeHandle(ref, () => ({
    draw(starts, stops, total) {
      const element = canvas.current;
      element.dataset.intervals = String(starts.length);
      const context = element.getContext?.('2d');
      if (!context || total <= 0) return starts.length;
      context.clearRect(0, 0, width, height);
      context.fillStyle = '#5b7f4b';
      const scale = width / total;
      let lastColumn = -1;
      for (let i = 0; i < starts.length; i++) {
        const x = Math.floor(starts[i] * scale);
        const end = Math.max(x + 1, Math.ceil(stops[i] * scale));
        if (end - 1 <= lastColumn) continue;
        context.fillRect(Math.max(x, lastColumn + 1), 6, end - Math.max(x, lastColumn + 1), height - 12);
        lastColumn = end - 1;
      }
      return starts.length;
    },
  }), [width, height]);
  return React.createElement('canvas', { ref: canvas, width, height, className: 'timeline-canvas', role: 'img', 'aria-label': 'Interval timeline' });
}

registerForeign('timeline-canvas', {
  component: TimelineCanvas,
  props: value => { const [width, height] = value.fields; return { width: Number(width), height: Number(height) }; },
  // Lean: draw : Array Nat → Array Nat → Nat → Action (HandleResult Nat)
  ops: invoke => ctor('Examples.Large.TimelineOps.mk', [
    (starts, stops, total) => invoke('draw', [starts.map(Number), stops.map(Number), Number(total)], count => BigInt(count)),
  ]),
});
