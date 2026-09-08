import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import * as domain from './.build/domain.mjs';

const call = (name, ...args) => {
  const result = domain[`Ordering.Fixtures.${name}`](...args);
  assert.equal(result.tag, 'Except.ok', `${name}: ${result.fields[0]}`);
  return result.fields[0];
};

test('native / LeanJS: deterministic ordering, all configurations, exact integers, Unicode', () => {
  const amounts = [0n, 1n, 9007199254740993n, 9223372036854775808n, 123456789012345678901234567890n];
  const labels = ['Café ☕ 東京 😀', 'é', '𐀀\uE000', 'quote"slash\\\nline', 'x\0y'];
  const actual = [];
  for (const amount of amounts) {
    for (const label of labels) {
      const result = call('scenario', amount, label);
      assert.deepEqual(result, [label, String(amount + 200n), String((amount + 200n) * 2n), '2', 'transitions:ok']);
      actual.push(result);
    }
    const prices = call('pricingCases', amount);
    // 25 admissible oat choices and 50 admissible large choices.
    assert.deepEqual(prices, [String(amount), '42', String(125n * amount + 25n * 75n + 50n * 125n), 'pricing:ok']);
    actual.push(prices);
    const stock = call('stockCases', amount);
    assert.deepEqual(stock, [String(amount + 1n), '0', 'stock:ok']);
    actual.push(stock);
  }
  assert.deepEqual(actual, JSON.parse(readFileSync(new URL('./.build/native.json', import.meta.url), 'utf8')));
});
