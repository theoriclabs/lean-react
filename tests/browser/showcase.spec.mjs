import { test, expect } from '@playwright/test';

test('showcase runs Lean code, exposes source, and links the example flows', async ({ page, context }) => {
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  await page.goto('/');
  await expect(page.getByRole('heading', { level: 1 })).toHaveText('Compose yourfrontend.Share the rest.');
  await expect(page.locator('#hero-count')).toHaveText('0');
  await page.getByRole('button', { name: 'Increment live counter' }).click();
  await expect(page.locator('#hero-count')).toHaveText('1');
  await page.getByRole('button', { name: 'Reset', exact: true }).click();
  await expect(page.locator('#hero-count')).toHaveText('0');
  await expect(page.locator('#counter-source')).toContainText('count.modify (· + 1)');
  await page.getByRole('navigation', { name: 'Playground examples' }).getByRole('link', { name: /Collection forms/ }).click();
  await expect(page).toHaveURL(/example=collections#playground/);
  await expect(page.locator('[data-example="collections"][aria-current]')).toHaveAttribute('aria-current', 'page');
  await page.locator('.source-details summary').click();
  await expect(page.locator('#example-source')).toContainText('Editor.list');
  await expect(page.locator('#example-source')).toBeVisible();
  await page.getByRole('navigation', { name: 'Playground examples' }).getByRole('link', { name: /Shared contexts/ }).click();
  await expect(page.locator('.greeting').first()).toHaveText('Provided: Hello, Lean');
  await page.getByLabel('Provider heading').fill('Across libraries');
  await expect(page.locator('.greeting').first()).toHaveText('Across libraries: Hello, Lean');
  await context.grantPermissions(['clipboard-read', 'clipboard-write']);
  await page.getByRole('button', { name: 'Copy commands' }).click();
  await expect(page.getByRole('button', { name: 'Copied!' })).toBeVisible();
  expect(await page.evaluate(() => navigator.clipboard.readText())).toContain('npm run dev');
  expect(errors).toEqual([]);
});

test('showcase navigation and each example fit a narrow viewport', async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  for (const example of ['tickets', 'collections', 'libraries']) {
    await page.goto(`/?example=${example}`);
    await expect(page.locator('#hero-count')).toBeVisible();
    await page.getByRole('link', { name: 'Explore the playground' }).click();
    await expect(page.locator('#root')).toBeVisible();
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
  }
});
