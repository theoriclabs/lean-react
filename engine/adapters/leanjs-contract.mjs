// Generic bridge between a generated HTTP client and the checked Lean Contract interpreter.
// Domain values/errors use their compiled Lean codecs; this file contains no scalar validators.
import { action, runAction } from '../runtime/actions.mjs';
import { CallFailure } from '../LeanContract/Fetch.mjs';
const ctor = (tag, fields = []) => ({tag, fields});
const bool = value => ctor(value ? 'Bool.true' : 'Bool.false');
const identity = value => ({namespace: value.fields[0], name: value.fields[1], version: value.fields[2]});
const identityValue = value => ctor('Contract.OperationId.mk', [value.namespace, value.name, value.version]);
const key = value => JSON.stringify([value.namespace, value.name, value.version]);

// JSON numbers have exact decimal mantissa/exponent in Lean. Refuse lossy native numbers.
function numberParts(value) {
  const [coefficient, power = '0'] = String(value).toLowerCase().split('e');
  const [whole, fraction = ''] = coefficient.split('.');
  let mantissa = BigInt(whole.replace('-', '') + fraction) * (value < 0 ? -1n : 1n);
  let exponent = BigInt(fraction.length) - BigInt(power);
  if (exponent < 0n) { mantissa *= 10n ** -exponent; exponent = 0n; }
  return [mantissa, exponent];
}

export function createJsonBridge(program) {
  const object = program['Contract.Browser.jsonObject'];
  const entries = program['Contract.Browser.jsonEntries'];
  const number = program['Contract.Browser.jsonNumber'];
  if (![object, entries, number].every(value => typeof value === 'function'))
    throw new TypeError('Compile Contract.Browser JSON helpers into the client module');
  function toLean(value) {
    if (value === null) return ctor('Lean.Json.null');
    if (typeof value === 'boolean') return ctor('Lean.Json.bool', [bool(value)]);
    if (typeof value === 'string' && value.isWellFormed()) return ctor('Lean.Json.str', [value]);
    if (typeof value === 'bigint') return number(value, 0n);
    if (typeof value === 'number' && Number.isFinite(value)) {
      if (Number.isInteger(value) && !Number.isSafeInteger(value)) throw new CallFailure('decode', 'json.unsafe_number');
      return number(...numberParts(value));
    }
    if (Array.isArray(value)) return ctor('Lean.Json.arr', [value.map(toLean)]);
    if (value && typeof value === 'object' && Object.getPrototypeOf(value) === Object.prototype)
      return object(Object.entries(value).map(([name, item]) => ctor('Prod.mk', [name, toLean(item)])));
    throw new CallFailure('decode', 'json.unsupported_value');
  }
  function fromLean(value) {
    switch (value?.tag) {
      case 'Lean.Json.null': return null;
      case 'Lean.Json.bool': return value.fields[0].tag === 'Bool.true';
      case 'Lean.Json.str': return value.fields[0];
      case 'Lean.Json.arr': return value.fields[0].map(fromLean);
      case 'Lean.Json.obj': {
        const fields = entries(value);
        if (fields.tag !== 'Option.some') throw new TypeError('JSON object helper mismatch');
        return Object.fromEntries(fields.fields[0].map(pair => [pair.fields[0], fromLean(pair.fields[1])]));
      }
      case 'Lean.Json.num': {
        const [mantissa, exponent] = value.fields[0].fields;
        // Exact integers beyond 2^53 stay exact as bigint (decision 15 references).
        if (BigInt(exponent) === 0n && !Number.isSafeInteger(Number(mantissa))) return BigInt(mantissa);
        const result = Number(`${mantissa}e-${exponent}`);
        if (!Number.isFinite(result) || (Number.isInteger(result) && !Number.isSafeInteger(result)))
          throw new CallFailure('decode', 'json.unsafe_number');
        const [nextMantissa, nextExponent] = numberParts(result);
        if (mantissa * 10n ** nextExponent !== nextMantissa * 10n ** exponent)
          throw new CallFailure('decode', 'json.lossy_number');
        return result;
      }
      default: throw new TypeError('Malformed Lean JSON ABI value');
    }
  }
  return Object.freeze({toLean, fromLean});
}

export function createContractInterpreter({program, client, request}) {
  const json = createJsonBridge(program);
  const frameworkError = program['Contract.Browser.frameworkError'];
  if (typeof frameworkError !== 'function') throw new TypeError('Compile Contract.Browser.frameworkError');
  const registry = new Map(Object.values(client.operations).map(operation => [key(operation.identity), operation]));
  const call = program.__leanjs_fn(6, (_kind, _input, _output, _error, contract, input) => action(async () => {
    const [nativeIdentity, inputCodec, outputCodec, errorCodec] = contract.fields;
    const operation = registry.get(key(identity(nativeIdentity)));
    if (!operation) return ctor('Except.error', [frameworkError(null, 'protocol', 'operation.not_found', nativeIdentity, nativeIdentity)]);
    try {
      const wireInput = json.fromLean(inputCodec.fields[1](input));
      let signal;
      if (request) {
        if (request.tag !== 'LeanReact.ResourceRequest.mk') throw new TypeError('Expected ResourceRequest ABI value');
        const controller = new AbortController();
        await runAction(request.fields[2](action(() => {controller.abort(); return ctor('PUnit.unit');})));
        if ((await runAction(request.fields[1])).tag === 'Bool.true') controller.abort();
        signal = controller.signal;
        if (signal.aborted) return ctor('Except.error', [frameworkError(null, 'cancelled', 'request.cancelled', nativeIdentity, nativeIdentity)]);
      }
      const response = await client.call(operation.identity, operation.input.decode(wireInput), {signal});
      const codec = response.ok ? outputCodec : errorCodec;
      const wire = response.ok ? operation.output.encode(response.value) : operation.error.encode(response.error);
      const decoded = codec.fields[2](json.toLean(wire));
      if (decoded.tag === 'Except.error') return ctor('Except.error', [ctor('Contract.CallError.decode', [decoded.fields[0]])]);
      return response.ok ? decoded : ctor('Except.error', [ctor('Contract.CallError.domain', [decoded.fields[0]])]);
    } catch (error) {
      // Only the existing typed framework failure is translated; programming errors stay observable.
      if (!(error instanceof CallFailure)) throw error;
      if (error.kind === 'decode' && error.code === 'server.decode') {
        const errors = program['Contract.Browser.decodeErrors'](json.toLean(error.detail));
        return ctor('Except.error', [ctor('Contract.CallError.decode', [errors.fields[0]])]);
      }
      const expected = error.detail?.expected?.namespace ? identityValue(error.detail.expected) : nativeIdentity;
      const received = error.detail?.received?.namespace ? identityValue(error.detail.received) : nativeIdentity;
      return ctor('Except.error', [frameworkError(null, error.kind, error.code, expected, received)]);
    }
  }));
  return ctor('Contract.Interpreter.mk', [call]);
}
