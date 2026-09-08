import * as lean from './generated/domain.mjs';

export function preview(c) {
  const result = lean['Cafe.preview'](c.temperature, c.size, c.milk, c.shots,
    { tag: c.decaf ? 'Bool.true' : 'Bool.false', fields: [] });
  if (result.startsWith('ok:')) return { ok: true, priceMinor: result.slice(3) };
  return { ok: false, error: result.slice(6) };
}
