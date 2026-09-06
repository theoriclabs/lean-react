import { test, expect } from '@playwright/test';

test('Lean-authored composition, events, validation, and shared editing behavior', async ({ page }) => {
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  await page.goto('/');
  await expect(page.getByRole('heading', { name: 'Tickets, composed your way' })).toBeVisible();
  await page.getByRole('button', { name: 'Increment First counter' }).click();
  await expect(page.locator('.counter strong').first()).toHaveText('1');
  await expect(page.locator('.counter strong').nth(1)).toHaveText('10');
  await expect(page.locator('.board .card')).toHaveCount(3);
  await page.getByRole('button', { name: 'Show inbox' }).click();
  await expect(page.locator('.inbox .card')).toHaveCount(3);
  await page.getByRole('button', { name: 'Swap card footer' }).click();
  await expect(page.locator('.card .note').first()).toHaveText('Next step: Done');
  await page.getByRole('button', { name: 'Edit ticket', exact: true }).first().click();
  await page.getByLabel('Ticket title', { exact: true }).fill('');
  await page.getByRole('button', { name: 'Save changes' }).click();
  await expect(page.getByRole('status')).toHaveText('Give the ticket a title.');
  await expect(page.getByLabel('Ticket title', { exact: true })).toHaveValue('');
  await page.getByLabel('Ticket title', { exact: true }).fill('One shared Lean edit');
  await page.getByRole('button', { name: 'Swap field editor' }).click();
  await expect(page.locator('textarea#ticket-title')).toHaveValue('One shared Lean edit');
  await page.getByRole('button', { name: 'Save changes' }).click();
  await expect(page.getByRole('status')).toHaveText('Saved.');
  await expect(page.locator('.card h3').first()).toHaveText('One shared Lean edit');
  await page.getByRole('button', { name: 'Swap editor layout' }).click();
  await expect(page.getByRole('heading', { name: 'Ticket detail', exact: true })).toBeVisible();
  await page.getByLabel('Ticket title', { exact: true }).fill('The same hook in a page');
  await page.getByRole('button', { name: 'Save changes' }).click();
  await expect(page.locator('.card h3').first()).toHaveText('The same hook in a page');
  await page.screenshot({ path: 'test-results/tickets.png', fullPage: true });
  expect(errors).toEqual([]);
});

test('small viewport retains usable inputs and controls', async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto('/');
  await page.getByRole('button', { name: 'Edit ticket', exact: true }).first().click();
  await expect(page.getByLabel('Ticket title', { exact: true })).toBeVisible();
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
});
