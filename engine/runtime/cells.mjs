import { action, duringRender } from './actions.mjs';

/** Immediate local transitions; notifications/render state belong to the consumer. */
export function createCellHooks(React, runtime) {
  return {
    useCell(initial, site = '') {
      return runtime.primitiveHook('cell', site, () => {
        const reference = React.useRef({ value: initial });
        return {
          read: action(() => reference.current.value),
          modifyGet: transition => action(() => {
            const change = duringRender(() => transition(reference.current.value));
            if (!change || typeof change.then === 'function' || !Object.hasOwn(change, 'result') || !Object.hasOwn(change, 'nextValue'))
              throw new TypeError('Cell transitions must synchronously return { result, nextValue }');
            const { result, nextValue } = change;
            reference.current.value = nextValue;
            return result;
          }),
        };
      });
    },
  };
}
