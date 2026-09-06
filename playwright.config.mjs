import { defineConfig } from '@playwright/test';

export default defineConfig({
  testDir: './tests/browser',
  testMatch: 'tickets.spec.mjs',
  workers: 1,
  use: {
    baseURL: 'http://127.0.0.1:4173',
    viewport: { width: 1360, height: 1000 },
    launchOptions: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH
      ? { executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH } : {},
  },
  webServer: {
    command: 'node scripts/dev.mjs --no-build',
    url: 'http://127.0.0.1:4173',
    timeout: 15_000,
  },
});
