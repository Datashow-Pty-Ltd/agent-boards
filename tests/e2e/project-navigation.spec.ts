import { expect, test } from "@playwright/test";

test("opens a project board and supports keyboard drawer dismissal", async ({ page }) => {
  await page.goto("/");
  await expect(page.getByRole("heading", { name: "Project delivery" })).toBeVisible();

  const project = page.locator(".project-card").first();
  await expect(project).toBeVisible();
  await project.click();

  await expect(page.getByRole("navigation", { name: "Project views" })).toBeVisible();
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
