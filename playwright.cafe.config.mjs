import { defineConfig } from '@playwright/test';
export default defineConfig({
  testDir: './tests/browser', testMatch: 'cafe.spec.mjs', workers: 1, timeout: 30000,
  use: { baseURL: 'http://127.0.0.1:4182', viewport: { width: 1440, height: 1100 },
    launchOptions: { executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH },
    screenshot: 'only-on-failure', trace: 'retain-on-failure' },
  webServer: { command: 'node scripts/cafe-test-server.mjs', url: 'http://127.0.0.1:4182/health/ready',
    timeout: 30000, reuseExistingServer: false },
});
