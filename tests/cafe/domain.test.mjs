import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { preview } from '../../examples/cafe/domain.mjs';
test('all 180 café configurations agree with native Lean and independent exact price expectations', () => {
  const native = execFileSync('lake', ['env', 'lean', '--run', 'tests/cafe/Vectors.lean'], { encoding: 'utf8' }).trim().split('\n');
  const actual = []; let valid = 0;
  for (const temperature of ['hot', 'iced']) for (const size of ['small', 'regular', 'large'])
    for (const milk of ['whole', 'skim', 'oat', 'almond', 'soy']) for (const shots of ['single', 'double', 'triple'])
      for (const decaf of [false, true]) {
        const result = preview({ temperature, size, milk, shots, decaf });
        if (temperature === 'iced' && size === 'small') assert.deepEqual(result, { ok: false, error: 'small_iced' });
        else if (decaf && shots === 'triple') assert.deepEqual(result, { ok: false, error: 'decaf_triple' });
        else {
          const cents = 450 + { small: -75, regular: 0, large: 100 }[size] +
            { whole: 0, skim: 0, oat: 75, almond: 75, soy: 50 }[milk] +
            { single: -50, double: 0, triple: 75 }[shots] + (temperature === 'iced' ? 25 : 0);
          assert.deepEqual(result, { ok: true, priceMinor: String(cents) }); valid++;
        }
        actual.push(result.ok ? `ok:${result.priceMinor}` : `error:${result.error}`);
      }
  assert.equal(actual.length, 180); assert.equal(valid, 125); assert.deepEqual(actual, native);
});
