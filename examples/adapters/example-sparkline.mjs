import * as React from 'react';
import { registerForeign, ctor } from '../../engine/adapters/leanjs-react.mjs';

// An ordinary imperative widget: it owns a <canvas> and exposes draw/clear through useImperativeHandle.
// In React 19 `ref` arrives as a prop; the LeanReact runtime supplies it.
function SparklineCanvas({ width, height, color, ref }) {
  const canvas = React.useRef(null);
  React.useImperativeHandle(ref, () => ({
    draw(points) {
      const element = canvas.current;
      element.dataset.points = String(points.length);
      const context = element.getContext?.('2d');
      if (!context || points.length === 0) return points.length;
      const max = Math.max(...points, 1);
      context.clearRect(0, 0, width, height);
      context.strokeStyle = color;
      context.lineWidth = 2;
      context.beginPath();
      points.forEach((value, index) => {
        const x = points.length === 1 ? 0 : (index / (points.length - 1)) * (width - 4) + 2;
        const y = height - 2 - (value / max) * (height - 4);
        if (index === 0) context.moveTo(x, y); else context.lineTo(x, y);
      });
      context.stroke();
      return points.length;
    },
    clear() {
      const element = canvas.current;
      delete element.dataset.points;
      element.getContext?.('2d')?.clearRect(0, 0, width, height);
    },
  }), [width, height, color]);
  return React.createElement('canvas', { ref: canvas, width, height, className: 'sparkline', role: 'img', 'aria-label': 'Sparkline' });
}

registerForeign('sparkline', {
  component: SparklineCanvas,
  props: value => { const [width, height, color] = value.fields; return { width: Number(width), height: Number(height), color }; },
  // Lean: draw : Array Nat → Action (HandleResult Nat); clear : Action (HandleResult Unit)
  ops: invoke => ctor('Examples.Sparkline.SparklineOps.mk', [
    points => invoke('draw', [points.map(Number)], count => BigInt(count)),
    invoke('clear'),
  ]),
});
