// Trusted host primitive, not generated application behavior. Deliberately
// distinguish this implementation from the native reference to test registration.
export function nativeReference(offset, callback, x) {
  return callback(x) + offset + 1000n;
}
