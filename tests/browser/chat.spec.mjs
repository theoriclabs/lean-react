import { test, expect } from '@playwright/test';

test('a Lean-owned chat thread renders through assistant-ui, sends, stops, and takes a drafted reply through the handle', async ({ page }) => {
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  page.on('console', message => { if (message.type() === 'error') errors.push(message.text()); });
  await page.goto('/?example=chat');
  const status = page.getByRole('status');
  const messages = page.locator('.aui-message');
  const input = page.locator('.aui-composer-input');
  await expect(status).toHaveText('Thread ready.');
  await expect(messages).toHaveCount(3);
  await expect(messages.nth(2)).toHaveAttribute('data-role', 'assistant');
  await expect(messages.nth(2).locator('.aui-tool-name')).toHaveText('list_files');
  await expect(messages.nth(2).locator('.aui-tool-result')).toContainText('lakefile.toml');

  await input.fill('Is there a README?');
  await page.getByRole('button', { name: 'Send' }).click();
  await expect(status).toHaveText('Sent: Is there a README?');
  await expect(messages).toHaveCount(5);
  await expect(messages.nth(3)).toHaveText('Is there a README?');
  await expect(page.getByRole('button', { name: 'Stop' })).toBeVisible();
  await page.getByRole('button', { name: 'Stop' }).click();
  await expect(status).toHaveText('Cancelled.');
  await expect(messages.nth(4)).toHaveText('Stopped.');
  await expect(page.getByRole('button', { name: 'Send' })).toBeVisible();

  await page.getByRole('button', { name: 'Draft a reply' }).click();
  await expect(status).toHaveText('Drafted.');
  await expect(input).toHaveValue('Thanks, that is all.');
  await page.getByRole('button', { name: 'Submit the draft' }).click();
  await expect(messages).toHaveCount(7);
  await expect(messages.nth(5)).toHaveText('Thanks, that is all.');
  await expect(input).toHaveValue('');
  await page.getByRole('button', { name: 'Complete the turn' }).click();
  await expect(status).toHaveText('Turn complete.');
  await expect(messages.nth(6)).toHaveText('Done.');
  await expect(page.getByTestId('chat-count')).toHaveText('7 messages');
  expect(errors).toEqual([]);
});
