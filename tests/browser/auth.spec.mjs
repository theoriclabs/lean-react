import { test, expect } from '@playwright/test';

test('signup, reload, protected request, logout and login use real server sessions', async ({ page, context }) => {
  await page.goto('/');
  await page.getByRole('button', { name: 'Sign up', exact: true }).click();
  await page.getByLabel('Username', { exact: true }).fill('browser_alice');
  await page.getByLabel('Password', { exact: true }).fill('a browser password with spaces 🔐');
  await page.getByRole('button', { name: 'Create account', exact: true }).click();
  await expect(page.getByRole('heading', { name: 'Signed in as browser_alice' })).toBeVisible();
  const cookies = await context.cookies();
  const cookie = cookies.find(cookie => cookie.name === 'leanapp_session');
  expect(cookie.httpOnly).toBe(true); expect(cookie.sameSite).toBe('Strict');
  expect(await page.evaluate(() => document.cookie)).not.toContain('leanapp_session');
  expect(await page.evaluate(() => localStorage.length + sessionStorage.length)).toBe(0);
  await page.getByRole('button', { name: 'Check who I am' }).click();
  await expect(page.getByText('Server confirmed: browser_alice')).toBeVisible();
  await page.reload();
  await expect(page.getByRole('heading', { name: 'Signed in as browser_alice' })).toBeVisible();
  await page.getByRole('button', { name: 'Log out' }).click();
  await expect(page.getByRole('heading', { name: 'Log in', exact: true })).toBeVisible();
  await page.getByLabel('Username', { exact: true }).fill('BROWSER_ALICE');
  await page.getByLabel('Password', { exact: true }).fill('the deliberately wrong password');
  await page.locator('form').getByRole('button', { name: 'Log in', exact: true }).click();
  await expect(page.getByText('The username or password is incorrect.')).toBeVisible();
  await expect(page.getByLabel('Password', { exact: true })).toHaveValue('');
  await page.getByLabel('Password', { exact: true }).fill('a browser password with spaces 🔐');
  await page.locator('form').getByRole('button', { name: 'Log in', exact: true }).click();
  await expect(page.getByRole('heading', { name: 'Signed in as browser_alice' })).toBeVisible();
});

test('invalid signup preserves username and focuses password without storing credentials', async ({ page }) => {
  await page.goto('/');
  await page.getByRole('button', { name: 'Sign up', exact: true }).click();
  await page.getByLabel('Username', { exact: true }).fill('browser_bob');
  await page.getByLabel('Password', { exact: true }).fill('short');
  await page.getByRole('button', { name: 'Create account', exact: true }).click();
  await expect(page.getByRole('status')).toContainText('15–128 characters');
  await expect(page.getByLabel('Password', { exact: true })).toBeFocused();
  await expect(page.getByLabel('Username', { exact: true })).toHaveValue('browser_bob');
  await expect(page.getByLabel('Password', { exact: true })).toHaveValue('');
});
