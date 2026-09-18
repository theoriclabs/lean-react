import { test, expect } from '@playwright/test';

test('typed form: blur validation, Enter-to-submit without reload, paste snapshot, and prevented defaults', async ({ page, context }) => {
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  await page.goto('/?example=forms');
  // The document sees the event after React's root listener, so `defaultPrevented` reflects the Lean KeyOutcome.
  await page.evaluate(() => {
    window.__leanreactSession = 'kept';
    document.addEventListener('keydown', event => { window.__prevented = event.defaultPrevented; });
  });
  const prevented = () => page.evaluate(() => window.__prevented);
  const name = page.getByTestId('feedback-name');
  const message = page.getByTestId('feedback-message');
  const status = page.getByTestId('feedback-status');
  await expect(message).toHaveCSS('resize', 'vertical');

  await name.focus();
  await page.keyboard.press('Tab');
  await expect(page.getByRole('alert')).toHaveText('Name is required.');
  await name.fill('Ada');
  await name.blur();
  await expect(page.getByRole('alert')).toHaveText('');
  await page.getByTestId('feedback-topic').selectOption('bug');

  await name.press('Enter');
  await expect(status).toHaveText('Sent A bug report from Ada (0 characters).');
  expect(await page.evaluate(() => window.__leanreactSession)).toBe('kept');
  await expect(page).toHaveURL(/example=forms/);

  await context.grantPermissions(['clipboard-read', 'clipboard-write']);
  await page.evaluate(() => navigator.clipboard.writeText('Pasted line'));
  await message.click();
  await page.keyboard.press('ControlOrMeta+V');
  await expect(page.getByTestId('feedback-pasted')).toHaveText('Pasted 11 characters.');
  await expect(message).toHaveValue('Pasted line');

  await page.keyboard.press('Shift+Enter');
  expect(await prevented()).toBe(false);
  await page.keyboard.type('second');
  await expect(message).toHaveValue('Pasted line\nsecond');
  await page.keyboard.press('Enter');
  expect(await prevented()).toBe(true);
  await expect(status).toHaveText('Sent A bug report from Ada (18 characters).');
  await expect(message).toHaveValue('Pasted line\nsecond');

  await page.keyboard.press('Control+s');
  expect(await prevented()).toBe(true);
  await expect(status).toHaveText('Draft kept locally.');
  await page.keyboard.press('s');
  expect(await prevented()).toBe(false);
  await expect(message).toHaveValue('Pasted line\nseconds');

  await page.getByRole('button', { name: 'Clear' }).click();
  await expect(message).toHaveValue('');
  await expect(status).toHaveText('');
  expect(errors).toEqual([]);
});
