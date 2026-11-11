import { defineConfig } from "@playwright/test";

export default defineConfig({
  testDir: "./tests/e2e",
  timeout: 30_000,
  forbidOnly: Boolean(process.env.CI),
  retries: process.env.CI ? 1 : 0,
  reporter: process.env.CI ? "github" : "list",
  use: {
    baseURL: process.env.AGENT_BOARDS_URL ?? "http://127.0.0.1:4747",
    trace: "retain-on-failure",
    screenshot: "only-on-failure",
  },
});
