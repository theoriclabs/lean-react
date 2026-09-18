import { test, expect } from '@playwright/test';

test('typed routes: deep link, in-place link clicks, back/forward, navigate/replace, and notFound', async ({ page }) => {
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  await page.goto('/router/tickets/2');
  await expect(page.getByRole('heading', { level: 2 })).toHaveText('Ticket 2');
  await expect(page.getByText('Write the release notes')).toBeVisible();
  await page.evaluate(() => { window.__leanreactSession = 'kept'; });

  await page.getByTestId('link-home').click();
  await expect(page).toHaveURL(/\/router\/$/);
  await expect(page.getByRole('heading', { level: 2 })).toHaveText('Tickets');
  expect(await page.evaluate(() => window.__leanreactSession)).toBe('kept');

  await page.getByTestId('link-ticket-3').click();
  await expect(page).toHaveURL(/\/router\/tickets\/3$/);
  await expect(page.getByRole('heading', { level: 2 })).toHaveText('Ticket 3');
  expect(await page.evaluate(() => window.__leanreactSession)).toBe('kept');

  await page.goBack();
  await expect(page.getByRole('heading', { level: 2 })).toHaveText('Tickets');
  await page.goForward();
  await expect(page.getByRole('heading', { level: 2 })).toHaveText('Ticket 3');
  await expect(page.getByTestId('location')).toHaveText('/router/tickets/3');

  await page.getByRole('button', { name: 'Back' }).click();
  await expect(page.getByRole('heading', { level: 2 })).toHaveText('Tickets');
  await page.getByTestId('link-ticket-1').click();
  await page.getByRole('button', { name: 'Replace with About' }).click();
  await expect(page).toHaveURL(/\/router\/about$/);
  await expect(page.getByRole('heading', { level: 2 })).toHaveText('About');
  await page.goBack();
  await expect(page.getByRole('heading', { level: 2 })).toHaveText('Tickets');
  await page.getByTestId('link-about').click();
  await expect(page.getByRole('heading', { level: 2 })).toHaveText('About');
  expect(await page.getByRole('link', { name: 'GitHub' }).getAttribute('href')).toBe('https://github.com/theoriclabs/lean-react');
  expect(await page.evaluate(() => window.__leanreactSession)).toBe('kept');

  await page.goto('/router/nowhere');
  await expect(page.getByRole('alert')).toContainText('No screen for /router/nowhere.');
  await page.getByRole('link', { name: 'Go to the tickets' }).click();
  await expect(page).toHaveURL(/\/router\/$/);
  await expect(page.getByRole('heading', { level: 2 })).toHaveText('Tickets');
  expect(errors).toEqual([]);
});
