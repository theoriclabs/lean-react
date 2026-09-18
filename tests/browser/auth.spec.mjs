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

test('two devices: revoking one session from the other signs out only the revoked side', async ({ browser }) => {
  const password = 'a two device password with spaces 🔐';
  const laptop = await (await browser.newContext()).newPage();
  const phone = await (await browser.newContext()).newPage();
  await laptop.goto('/');
  await laptop.getByRole('button', { name: 'Sign up', exact: true }).click();
  await laptop.getByLabel('Username', { exact: true }).fill('browser_carol');
  await laptop.getByLabel('Password', { exact: true }).fill(password);
  await laptop.getByRole('button', { name: 'Create account', exact: true }).click();
  await expect(laptop.getByRole('heading', { name: 'Signed in as browser_carol' })).toBeVisible();
  await phone.goto('/');
  await phone.getByLabel('Username', { exact: true }).fill('browser_carol');
  await phone.getByLabel('Password', { exact: true }).fill(password);
  await phone.locator('form').getByRole('button', { name: 'Log in', exact: true }).click();
  await expect(phone.getByRole('heading', { name: 'Signed in as browser_carol' })).toBeVisible();
  // The laptop session survived the second login and both devices are listed.
  await laptop.getByRole('button', { name: 'Check who I am' }).click();
  await expect(laptop.getByText('Server confirmed: browser_carol')).toBeVisible();
  await phone.getByRole('button', { name: 'Refresh sessions' }).click();
  const items = phone.getByRole('list', { name: 'Sessions' }).getByRole('listitem');
  await expect(items).toHaveCount(2);
  await expect(items.filter({ hasText: '(this device)' })).toHaveCount(1);
  await items.filter({ hasNotText: '(this device)' }).getByRole('button', { name: /^Revoke/ }).click();
  await expect(items).toHaveCount(1);
  // Revoked side: the next protected request is 401 and the client drops the identity.
  await laptop.getByRole('button', { name: 'Check who I am' }).click();
  await expect(laptop.getByRole('heading', { name: 'Signed in as browser_carol' })).toBeHidden();
  await expect(laptop.getByLabel('Password', { exact: true })).toBeVisible();
  await laptop.reload();
  await expect(laptop.getByRole('heading', { name: 'Log in', exact: true })).toBeVisible();
  // Revoker keeps working.
  await phone.getByRole('button', { name: 'Check who I am' }).click();
  await expect(phone.getByText('Server confirmed: browser_carol')).toBeVisible();
  await phone.getByRole('button', { name: 'Sign out everywhere' }).click();
  await expect(phone.getByRole('heading', { name: 'Log in', exact: true })).toBeVisible();
  await expect(phone.getByRole('status')).toContainText('signed out everywhere');
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
