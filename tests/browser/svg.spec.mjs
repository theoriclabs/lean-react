import { test, expect } from '@playwright/test';

test('an SVG diagram draws arrows between boxes, and a timeline scrubs when dragged and zooms with the wheel', async ({ page }) => {
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  page.on('console', message => { if (message.type() === 'error') errors.push(message.text()); });
  await page.goto('/?example=svg');

  const diagram = page.getByRole('img', { name: 'Data path' });
  await expect(diagram).toBeVisible();
  await expect(diagram.locator('[data-box]')).toHaveCount(4);
  // Each arrow really ends at the box it points to: its rendered end touches the target's left edge.
  const geometry = await diagram.evaluate(svg => {
    const box = id => svg.querySelector(`[data-box="${id}"] rect`).getBoundingClientRect();
    const line = svg.querySelector('[data-arrow="memory->registers"] line').getBoundingClientRect();
    return { lineRight: line.right, registersLeft: box('registers').left, memoryRight: box('memory').right,
      markers: svg.querySelectorAll('line[marker-end="url(#arrow)"]').length };
  });
  expect(geometry.markers).toBe(3);
  expect(Math.abs(geometry.lineRight - geometry.registersLeft)).toBeLessThan(2);
  expect(Math.abs(geometry.memoryRight - (geometry.lineRight - (geometry.registersLeft - geometry.memoryRight)))).toBeLessThan(2);

  const chart = page.getByTestId('timeline');
  const cursorText = page.getByTestId('timeline-cursor-text');
  const range = page.getByTestId('timeline-window');
  await expect(range).toHaveText('Showing cycles 0–4096 of 4096 (256 intervals)');
  await chart.scrollIntoViewIfNeeded();
  const box = await chart.boundingBox();
  const at = fraction => box.x + box.width * fraction;
  const cycle = async () => Number((await cursorText.textContent()).replace('Cycle ', ''));

  // Press at the middle, drag right, past the edge (pointer capture keeps the drag), release.
  await page.mouse.move(at(0.5), box.y + box.height / 2);
  await page.mouse.down();
  await expect.poll(async () => Math.abs(await cycle() - 2048)).toBeLessThanOrEqual(16);
  await page.mouse.move(at(0.75), box.y + box.height / 2, { steps: 4 });
  await expect.poll(async () => Math.abs(await cycle() - 3072)).toBeLessThanOrEqual(16);
  await page.mouse.move(box.x + box.width + 80, box.y + box.height / 2, { steps: 4 });
  await expect(cursorText).toHaveText('Cycle 4095');
  await page.mouse.up();
  await page.mouse.move(at(0.1), box.y + box.height / 2);
  await expect(cursorText).toHaveText('Cycle 4095');

  // Wheel up over a quarter of the chart zooms in around cycle ~1024, without scrolling the page.
  const scrollBefore = await page.evaluate(() => window.scrollY);
  await page.mouse.move(at(0.25), box.y + box.height / 2);
  await page.mouse.wheel(0, -100);
  await expect(range).toContainText('(128 intervals)');
  const [start, end] = (await range.textContent()).match(/cycles (\d+)–(\d+)/).slice(1).map(Number);
  expect(end - start).toBe(2048);
  expect(Math.abs(start - 512)).toBeLessThanOrEqual(16);
  expect(await page.evaluate(() => window.scrollY)).toBe(scrollBefore);
  await page.mouse.wheel(0, 100);
  await expect(range).toHaveText('Showing cycles 0–4096 of 4096 (256 intervals)');
  expect(errors).toEqual([]);
});
