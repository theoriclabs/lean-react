import { defineConfig } from '@playwright/test';
import base from './playwright.config.mjs';

export default defineConfig({
  ...base,
  testMatch: 'native.spec.mjs',
  webServer: { ...base.webServer, command: 'node scripts/native-browser-server.mjs' },
});
