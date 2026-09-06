import { test, expect } from '@playwright/test';

const operation = name => ({ namespace: 'leanreact.tickets', name, version: '1' });
const envelope = (name, input) => ({ operation: operation(name), kind: name === 'list' ? 'query' : 'command', input });

test('the same compiled workspace uses SQLite, persists saves, and keeps drafts through conflicts', async ({ page, request }) => {
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  await page.goto('/?service=native');
  await expect(page.locator('.card')).toHaveCount(3);
  await page.getByRole('button', { name: 'Edit ticket', exact: true }).first().click();
  await page.getByLabel('Ticket title', { exact: true }).fill('Saved through LeanDB');
  await page.getByRole('button', { name: 'Save changes' }).click();
  await expect(page.getByRole('status')).toHaveText('Saved.');
  await page.reload();
  await expect(page.locator('.card h3').first()).toHaveText('Saved through LeanDB');
  await page.getByRole('button', { name: 'Edit ticket', exact: true }).first().click();
  await page.getByLabel('Ticket title', { exact: true }).fill('My conflicting draft');

  const listed = await request.post('/api/tickets/list', { data: envelope('list', null) });
  expect(listed.status()).toBe(200);
  const current = (await listed.json()).value[0];
  const changed = await request.post('/api/tickets/save', { data: envelope('save', {
    id: current.id, expectedRevision: current.revision, title: 'Another writer', status: current.value.status,
  }) });
  expect(changed.status()).toBe(200);

  await page.getByRole('button', { name: 'Save changes' }).click();
  await expect(page.getByRole('status')).toHaveText('This ticket changed. Your draft has been kept.');
  await expect(page.getByLabel('Ticket title', { exact: true })).toHaveValue('My conflicting draft');
  await page.getByRole('button', { name: 'Reload tickets' }).click();
  await expect(page.locator('.card h3').first()).toHaveText('Another writer');
  await expect(page.getByLabel('Ticket title', { exact: true })).toHaveValue('My conflicting draft');
  await page.getByRole('button', { name: 'Save changes' }).click();
  await expect(page.getByRole('status')).toHaveText('Saved.');
  await page.reload();
  await expect(page.locator('.card h3').first()).toHaveText('My conflicting draft');
  expect(errors).toEqual([]);
});

test('the public HTTP boundary rejects incompatible operations and malformed domain input', async ({ request }) => {
  const mismatch = await request.post('/api/tickets/list', { data: {
    ...envelope('list', null), operation: { ...operation('list'), version: 'old-client' },
  } });
  expect(mismatch.status()).toBe(409);
  expect((await mismatch.json()).tag).toBe('incompatible');
  const listed = await request.post('/api/tickets/list', { data: envelope('list', null) });
  const current = (await listed.json()).value[0];
  const invalid = await request.post('/api/tickets/save', { data: envelope('save', {
    id: current.id, expectedRevision: current.revision, title: '', status: current.value.status,
  }) });
  expect(invalid.status()).toBe(400);
  expect((await invalid.json()).tag).toBe('decode');
});
