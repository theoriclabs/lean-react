import { defineConfig } from '@playwright/test';

export default defineConfig({
  testDir: './tests/browser', testMatch: 'auth.spec.mjs', workers: 1, timeout: 30000,
  use: { baseURL: 'http://127.0.0.1:4177', headless: true,
    launchOptions: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH ? { executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH } : {} },
  webServer: { command: 'node scripts/auth-browser-server.mjs', url: 'http://127.0.0.1:4177', timeout: 60000, reuseExistingServer: false },
});
