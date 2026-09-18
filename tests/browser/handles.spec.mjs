import { test, expect } from '@playwright/test';

test('a typed handle drives an imperative canvas, survives unmount with a typed result, and follows a keyed remount', async ({ page }) => {
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  page.on('console', message => { if (message.type() === 'error') errors.push(message.text()); });
  await page.goto('/?example=canvas');
  const status = page.getByRole('status');
  const events = page.getByTestId('sparkline-events');
  const canvas = page.getByRole('img', { name: 'Sparkline' });
  // The playground mounts under StrictMode, which double-invokes effects in development; the lifecycle stays
  // balanced: every `gone` follows a `ready`, and the log ends with `ready` exactly when a canvas is mounted.
  const expectBalanced = async mounted => {
    const log = (await events.textContent()).split(' → ');
    expect(log.at(-1)).toBe(mounted ? 'ready' : 'gone');
    expect(log.filter(entry => entry === 'ready').length).toBe(log.filter(entry => entry === 'gone').length + (mounted ? 1 : 0));
  };
  await expect(status).toHaveText('Canvas ready.');
  await expectBalanced(true);

  await page.getByRole('button', { name: 'Draw next series' }).click();
  await expect(status).toHaveText('Drew 8 points.');
  await expect(canvas).toHaveAttribute('data-points', '8');
  // The 2D context really painted: at least one pixel is no longer transparent.
  expect(await canvas.evaluate(element => {
    const data = element.getContext('2d').getImageData(0, 0, element.width, element.height).data;
    for (let i = 3; i < data.length; i += 4) if (data[i] !== 0) return true;
    return false;
  })).toBe(true);
  await page.getByRole('button', { name: 'Clear' }).click();
  await expect(status).toHaveText('Cleared.');

  await page.getByRole('button', { name: 'Unmount canvas' }).click();
  await expect(status).toHaveText('Canvas gone.');
  await expectBalanced(false);
  await expect(canvas).toHaveCount(0);
  await page.getByRole('button', { name: 'Draw next series' }).click();
  await expect(status).toHaveText('The canvas was unmounted; nothing drawn.');

  await page.getByRole('button', { name: 'Mount canvas' }).click();
  await expect(status).toHaveText('Canvas ready.');
  await expectBalanced(true);
  await page.getByRole('button', { name: 'Draw next series' }).click();
  await expect(status).toHaveText('Drew 9 points.');

  const before = (await events.textContent()).split(' → ').length;
  await page.getByRole('button', { name: 'Recreate canvas' }).click();
  await expect(status).toHaveText('Canvas ready.');
  await expectBalanced(true);
  expect((await events.textContent()).split(' → ').length).toBeGreaterThan(before);
  await page.getByRole('button', { name: 'Draw next series' }).click();
  await expect(status).toHaveText('Drew 7 points.');
  await expect(canvas).toHaveAttribute('data-points', '7');
  expect(errors).toEqual([]);
});
