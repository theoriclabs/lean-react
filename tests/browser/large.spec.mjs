import { test, expect } from '@playwright/test';

test('a 100,000-row list and a wide grid render only their visible window, and a million-interval canvas maps clicks back', async ({ page }) => {
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  page.on('console', message => { if (message.type() === 'error') errors.push(message.text()); });
  await page.goto('/?example=large');

  const list = page.locator('[data-virtual=list][aria-label="Events"]');
  await expect(list).toBeVisible();
  const rows = list.locator('[role=listitem]');
  const window = await list.evaluate(element => ({ height: element.clientHeight }));
  const limit = Math.ceil(window.height / 28) + 1 + 2 * 4;
  expect(await rows.count()).toBeLessThanOrEqual(limit);
  // Scroll through the list with the wheel and by position: the rendered window follows.
  await list.hover();
  for (let i = 0; i < 5; i++) await page.mouse.wheel(0, 2000);
  await expect.poll(() => list.evaluate(element => element.scrollTop)).toBeGreaterThan(5000);
  await list.evaluate(element => { element.scrollTop = 28 * 70000; });
  await expect(list.locator('[data-index="70000"]')).toBeVisible();
  await expect(list.locator('[data-index="70000"]')).toHaveText('Event 70000 · cycle 1120000');
  expect(await rows.count()).toBeLessThanOrEqual(limit);
  await list.evaluate(element => { element.scrollTop = element.scrollHeight; });
  await expect(list.locator('[data-index="99999"]')).toBeVisible();
  // More data keeps the scroll position.
  const before = await list.evaluate(element => element.scrollTop);
  await page.getByRole('button', { name: 'Add 1,000 rows' }).click();
  await expect(page.getByTestId('event-count')).toHaveText('101000 rows');
  expect(await list.evaluate(element => element.scrollTop)).toBe(before);

  const grid = page.getByRole('grid', { name: 'Units by cycle' });
  await grid.evaluate(element => { element.scrollTop = 24 * 2000; element.scrollLeft = 72 * 150; });
  const label = grid.locator('[data-row="2005"][data-column="0"]');
  await expect(label).toHaveText('Unit 2005');
  // The label column stays at the grid's left edge while scrolled sideways.
  const [gridBox, labelBox] = [await grid.boundingBox(), await label.boundingBox()];
  expect(Math.abs(labelBox.x - gridBox.x)).toBeLessThan(3);
  expect(await grid.locator('[role=gridcell]').count()).toBeLessThan(400);

  const status = page.getByTestId('timeline-pick');
  await expect(status).toHaveText('Drew 1000000 intervals. Click one.', { timeout: 15000 });
  const frame = page.getByTestId('timeline-canvas');
  await frame.scrollIntoViewIfNeeded();
  const box = await frame.boundingBox();
  await page.mouse.click(box.x + 1, box.y + box.height / 2);
  await expect(status).toContainText(/^(Interval \d+|No interval at cycle \d+)/);
  // The click's cycle maps to the interval Lean reports (or to a gap between intervals).
  await page.mouse.click(box.x + box.width / 2, box.y + box.height / 2);
  const text = await status.textContent();
  const cycle = Number(text.match(/cycle (\d+)\)?$/)[1]);
  const index = Math.floor(cycle / 4);
  const stop = index * 4 + 1 + (index * 7) % 3;
  expect(text).toBe(cycle < stop
    ? `Interval ${index}: cycles ${index * 4}–${stop} (clicked cycle ${cycle})`
    : `No interval at cycle ${cycle}`);
  // The canvas really painted.
  expect(await page.locator('canvas.timeline-canvas').evaluate(canvas => {
    const data = canvas.getContext('2d').getImageData(0, 0, canvas.width, canvas.height).data;
    for (let i = 3; i < data.length; i += 4) if (data[i] !== 0) return true;
    return false;
  })).toBe(true);
  expect(errors).toEqual([]);
});
