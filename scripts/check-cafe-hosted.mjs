// Opt-in public smoke test. Creates two disposable accounts; removes its own recipe.
// Passwords, cookies and CSRF tokens stay in memory. Never use real credentials.
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { once } from 'node:events';
import { mkdir } from 'node:fs/promises';
import { chromium, expect } from '@playwright/test';

const origin = new URL(process.argv[2]).origin;
if (!origin.startsWith('https://') || !process.argv.includes('--allow-mutations'))
  throw new Error('Usage: node scripts/check-cafe-hosted.mjs HTTPS_ORIGIN --allow-mutations [--pause-for-restart]');
const browser = await chromium.launch({ executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH });
const alice = await browser.newContext({ viewport: { width: 1440, height: 1100 }, reducedMotion: 'reduce' });
const bob = await browser.newContext();
const page = await alice.newPage(), other = await bob.newPage();
const errors = [];
page.on('pageerror', error => errors.push(error.message));
other.on('pageerror', error => errors.push(error.message));
const username = `release_${randomUUID().slice(0, 12)}`, password = randomUUID() + randomUUID();
const recipeName = 'Release check: afternoon oat';
async function call(target, name, input, csrf = true) {
  return target.evaluate(async ({ name, input, csrf }) => {
    const headers = { 'X-LeanApp-Request': '1', 'Content-Type': 'application/json' };
    if (csrf) {
      const session = await fetch('/auth/session', { headers: { 'X-LeanApp-Request': '1' } }).then(r => r.json());
      headers['X-CSRF-Token'] = session.csrf;
    }
    const response = await fetch(`/api/recipes/${name}`, { method: 'POST', headers,
      body: JSON.stringify({ operation: { namespace: 'cafe', name, version: '1' },
        kind: name === 'list' ? 'query' : 'command', input }) });
    return { status: response.status, body: await response.json() };
  }, { name, input, csrf });
}
try {
  const ready = await alice.request.get(origin + '/health/ready');
  assert.equal(ready.status(), 200); assert.deepEqual(await ready.json(), { ready: true });
  assert.equal(ready.headers()['cache-control'], 'no-store');
  assert.match(ready.headers()['strict-transport-security'], /max-age=/);
  await page.goto(origin);
  assert.equal((await call(page, 'list', null, false)).status, 401);
  await expect(page.getByText('$4.50', { exact: true })).toBeVisible();
  await page.getByRole('radio', { name: 'Iced', exact: true }).check();
  await expect(page.getByRole('radio', { name: 'Small', exact: true })).toBeDisabled();
  await expect(page.getByRole('radio', { name: 'Small', exact: true })).toHaveAccessibleDescription(/no room for ice/);
  await page.getByRole('radio', { name: 'Large', exact: true }).check();
  await page.getByRole('radio', { name: 'Oat', exact: true }).check();
  await expect(page.getByText('$6.50', { exact: true })).toBeVisible();
  await page.getByLabel('Give your favorite a name').fill(recipeName);
  await mkdir(new URL('../.lake/', import.meta.url), { recursive: true });
  await page.screenshot({ path: new URL('../.lake/cafe-hosted.png', import.meta.url).pathname, fullPage: true });
  await page.getByRole('button', { name: 'Sign up to save' }).click();
  await page.getByLabel('Username', { exact: true }).fill(username);
  await page.getByLabel('Password', { exact: true }).fill(password);
  await page.getByRole('button', { name: /Create account/ }).click();
  await expect(page.getByRole('dialog')).not.toBeVisible();
  await expect(page.getByLabel('Give your favorite a name')).toHaveValue(recipeName);
  const cookies = await alice.cookies(origin);
  const cookie = cookies.find(c => c.name === '__Host-leanapp_session');
  assert.ok(cookie); assert.ok(cookie.secure && cookie.httpOnly);
  assert.equal(cookie.sameSite, 'Strict'); assert.equal(cookie.path, '/');
  assert.deepEqual(await page.evaluate(() => [document.cookie, localStorage.length, sessionStorage.length]), ['', 0, 0]);
  await page.getByRole('button', { name: /Save recipe/ }).click();
  await expect(page.getByRole('status').first()).toContainText('Recipe saved');
  const saved = (await call(page, 'list', null)).body.value;
  assert.equal(saved.length, 1); assert.equal(saved[0].priceMinor, '650');
  assert.equal((await call(page, 'delete', saved[0].id, false)).status, 403);
  assert.equal((await call(page, 'save', { name: 'Invalid', configuration: { ...saved[0].configuration, size: 'small' } })).status, 422);
  assert.equal((await call(page, 'save', { name: 'Forged', configuration: saved[0].configuration, priceMinor: '1' })).status, 400);
  const foreign = await alice.request.post(origin + '/api/recipes/delete', { headers: {
    origin: 'https://foreign.example', 'X-LeanApp-Request': '1' }, data: {} });
  assert.equal(foreign.status(), 403);
  await other.goto(origin);
  const registered = await other.evaluate(async body => {
    const response = await fetch('/auth/signup', { method: 'POST', headers: {
      'X-LeanApp-Request': '1', 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
    return response.status;
  }, { username: username + '_b', password: randomUUID() + randomUUID() });
  assert.equal(registered, 200);
  assert.deepEqual((await call(other, 'list', null)).body.value, []);
  assert.equal((await call(other, 'delete', saved[0].id)).status, 200);
  assert.deepEqual((await call(page, 'list', null)).body.value, saved);
  await page.getByRole('link', { name: /Saved recipes/ }).click();
  await page.reload();
  await expect(page.getByRole('heading', { name: recipeName })).toBeVisible();
  console.log('PASS: public HTTPS, disabled choices, signup, Secure/HttpOnly/Strict cookie, CSRF/origin, authoritative pricing, account isolation, save/reload.');
  if (process.argv.includes('--pause-for-restart')) {
    console.log('READY_FOR_RESTART: restart only the approved service, verify it is ready, then press Enter.');
    process.stdin.resume(); await once(process.stdin, 'data'); process.stdin.pause();
    await page.reload();
    await expect(page.getByRole('heading', { name: recipeName })).toBeVisible();
    assert.deepEqual((await call(page, 'list', null)).body.value, saved);
    assert.deepEqual((await call(other, 'list', null)).body.value, []);
    console.log('PASS: original sessions and isolated recipe data survived the provider restart.');
  }
  await page.getByRole('button', { name: 'Log out', exact: true }).click();
  await expect(page.getByRole('heading', { name: recipeName })).not.toBeVisible();
  await page.getByRole('button', { name: 'Log in', exact: true }).first().click();
  await page.getByLabel('Username', { exact: true }).fill(username.toUpperCase());
  await page.getByLabel('Password', { exact: true }).fill(password);
  await page.getByRole('dialog').getByRole('button', { name: /Log in/ }).last().click();
  await expect(page.getByRole('dialog')).not.toBeVisible();
  await expect(page.getByRole('heading', { name: recipeName })).toBeVisible();
  await page.getByRole('button', { name: `Delete ${recipeName}` }).click();
  await page.getByRole('button', { name: 'Delete recipe', exact: true }).click();
  await expect(page.getByRole('heading', { name: recipeName })).not.toBeVisible();
  await page.goto(origin + '/#configure');
  await page.setViewportSize({ width: 390, height: 844 });
  await page.getByRole('radio', { name: 'Triple', exact: true }).check();
  await expect(page.getByRole('checkbox')).toBeDisabled();
  assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth));
  await page.getByRole('link', { name: 'Why Lean', exact: true }).click();
  await expect(page.getByRole('heading', { name: 'Every cent accounted for' })).toBeVisible();
  assert.deepEqual(errors, []);
  console.log('PASS: logout/login, own-recipe deletion, mobile layout, Why Lean, no browser errors. Two empty disposable test accounts remain; no credentials recorded.');
} finally { await browser.close(); }
