import * as React from 'react';
import { runtime } from '../../engine/adapters/leanjs-react.mjs';

// A normal React component. A real adapter can import a component library here.
function ThirdPartyButton({ label, onClick, decoration }) {
  return React.createElement('button', { className: 'foreign-button', onClick }, label, decoration);
}

export function thirdPartyButton(props) {
  const [label, onPress, decoration] = props.fields;
  return runtime.foreignElement(ThirdPartyButton, { label, onClick: runtime.onPress(onPress), decoration });
}
