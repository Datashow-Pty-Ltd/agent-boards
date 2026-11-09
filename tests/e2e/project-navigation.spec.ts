import { expect, test } from "@playwright/test";

test("opens a project board and supports keyboard drawer dismissal", async ({ page }) => {
  await page.addInitScript(() => {
    window.localStorage.removeItem("agent-boards:first-run-tour:v1");
  });
  await page.goto("/");
  await expect(page.getByRole("heading", { name: "The board is the source of truth" })).toBeVisible();
  await page.getByRole("button", { name: "Skip tour" }).click();
  await expect(page.getByRole("heading", { name: "Project delivery" })).toBeVisible();

  const project = page.locator(".project-card").first();
  await expect(project).toBeVisible();
  await project.click();

  await expect(page.getByRole("navigation", { name: "Project views" })).toBeVisible();
  await page.getByRole("link", { name: "Project settings" }).click();
  await expect(page.getByRole("heading", { name: "Workflow configuration" })).toBeVisible();
  await page.getByRole("button", { name: "Save Backlog" }).click();
  await expect(page.getByText("Stage settings saved")).toBeVisible();
  await page.getByRole("link", { name: "Board", exact: true }).click();
  await expect(page.getByRole("heading", { name: "Kanban Delivery Board" })).toBeVisible();

  const card = page.locator(".work-card").first();
  if (await card.count()) {
    await card.click();
    await expect(page.getByRole("button", { name: /close/i })).toBeVisible();
    await page.keyboard.press("Escape");
    await expect(page.getByRole("button", { name: /close/i })).toBeHidden();
  }
});
