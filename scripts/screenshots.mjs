import { spawn } from 'node:child_process';
import { mkdir } from 'node:fs/promises';
import { resolve } from 'node:path';
import { chromium } from '@playwright/test';
import { projectRoot } from './build.mjs';

// Capture real browser output. Build first with `npm run screenshots`.
const server = spawn(process.execPath, ['scripts/dev.mjs', '--no-build'], {
  cwd: projectRoot, env: { ...process.env, PORT: '0' }, stdio: ['ignore', 'pipe', 'inherit'],
});
let browser;
const stop = () => { if (server.exitCode === null) server.kill('SIGTERM'); };
process.once('exit', stop);
try {
  const url = await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('Screenshot server did not start')), 15_000);
    let output = '';
    server.stdout.on('data', chunk => {
      output += chunk.toString();
      const match = output.match(/http:\/\/127\.0\.0\.1:\d+/);
      if (match) { clearTimeout(timer); resolve(match[0]); }
    });
    server.once('error', error => { clearTimeout(timer); reject(error); });
    server.once('exit', code => { clearTimeout(timer); reject(new Error(`Screenshot server exited: ${code}`)); });
  });
  browser = await chromium.launch({
    ...(process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH
      ? { executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH } : {}),
  });
  const page = await browser.newPage({ viewport: { width: 1440, height: 1050 }, deviceScaleFactor: 2, reducedMotion: 'reduce' });
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  const directory = resolve(projectRoot, 'docs/images');
  await mkdir(directory, { recursive: true });

  await page.goto(url);
  await page.locator('.board .card').first().waitFor();
  await page.getByRole('button', { name: 'Increment live counter' }).click();
  await page.getByRole('button', { name: 'Increment live counter' }).click();
  await page.getByRole('button', { name: 'Increment live counter' }).click();
  const stack = await page.locator('.stack-line').boundingBox();
  await page.screenshot({ path: resolve(directory, 'showcase.png'),
    clip: { x: 0, y: 0, width: 1440, height: Math.ceil(stack.y + stack.height + 35) } });

  await page.getByRole('button', { name: 'Edit ticket', exact: true }).first().click();
  await page.getByLabel('Ticket title', { exact: true }).fill('A domain we can share');
  await page.getByRole('button', { name: 'Save changes' }).click();
  await page.getByRole('status').filter({ hasText: 'Saved.' }).waitFor();
  await page.locator('#playground').screenshot({ path: resolve(directory, 'workspace.png') });

  await page.goto(`${url}/?example=collections`);
  await page.getByRole('article', { name: 'Row 1', exact: true }).getByRole('button', { name: 'Visited 0' }).click();
  await page.getByLabel('Title 1', { exact: true }).fill('Shared domain');
  await page.getByLabel('Detail 1', { exact: true }).fill('One definition, reused everywhere');
  await page.getByRole('button', { name: 'Add row', exact: true }).click();
  await page.getByRole('button', { name: 'Reverse rows' }).click();
  await page.getByRole('button', { name: 'Save rows' }).click();
  await page.getByRole('status').filter({ hasText: 'Fix 2 fields' }).waitFor();
  await page.locator('.source-details summary').click();
  await page.locator('#playground').screenshot({ path: resolve(directory, 'collections.png') });

  // A retained mobile view makes responsive layout inspection repeatable too.
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto(url);
  await page.locator('#hero-count').waitFor();
  const verification = resolve(projectRoot, '.verification/showcase');
  await mkdir(verification, { recursive: true });
  await page.screenshot({ path: resolve(verification, 'mobile.png'), fullPage: true });
  if (await page.evaluate(() => document.documentElement.scrollWidth > window.innerWidth)) {
    throw new Error('The showcase overflows the mobile viewport');
  }
  if (errors.length) throw new Error(`Page errors: ${errors.join('; ')}`);
  console.log('Saved README screenshots in docs/images/ and the mobile inspection in .verification/showcase/');
} finally {
  await browser?.close();
  stop();
}
