import { test, expect } from '@playwright/test';

test('sign up, add a note, see it after a reload', async ({ page }) => {
  const errors = []; page.on('pageerror', e => errors.push(e.message));
  await page.goto('/');
  await page.getByRole('button', { name: 'Sign up instead' }).click();
  await page.getByLabel('Username').fill('browser_notes');
  await page.getByLabel('Password').fill('a-browser-test-passphrase');
  await page.getByRole('button', { name: 'Create account' }).click();
  await expect(page.getByText('Signed in as')).toBeVisible();
  await expect(page.getByText('No notes yet.')).toBeVisible();
  await page.getByLabel('New note').fill('Call the dentist');
  await page.getByRole('button', { name: 'Add note' }).click();
  await expect(page.getByRole('status')).toContainText('Note added.');
  await expect(page.getByRole('listitem').filter({ hasText: 'Call the dentist' })).toBeVisible();
  await page.reload();
  await expect(page.getByRole('listitem').filter({ hasText: 'Call the dentist' })).toBeVisible();
  expect(errors).toEqual([]);
});
