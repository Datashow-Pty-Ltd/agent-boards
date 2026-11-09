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

  await expect(page.locator(".kanban-phase")).toHaveCount(5);
  await expect(page.locator(".stage-control")).toHaveCount(9);
  expect(await page.evaluate(() => document.documentElement.scrollHeight <= window.innerHeight + 1)).toBe(true);

  const laneOverflow = await page.locator(".phase-stages").evaluateAll((lanes) =>
    lanes.map((lane) => getComputedStyle(lane).overflowY),
  );
  expect(laneOverflow).toEqual(["auto", "auto", "auto", "auto", "auto"]);
  expect(await page.locator(".kanban-scroll").evaluate((element) => getComputedStyle(element).overflowY)).toBe("hidden");
  expect(await page.evaluate(() => window.scrollY)).toBe(0);

  const stateControl = page.locator(".stage-control").first();
  await expect(stateControl).toHaveAttribute("aria-expanded", "true");
  await stateControl.click();
  await expect(stateControl).toHaveAttribute("aria-expanded", "false");
  await stateControl.click();
  const storyGroup = page.locator(".work-type-control").filter({ hasText: "Stories" }).first();
  await storyGroup.click();
  await expect(storyGroup).toHaveAttribute("aria-expanded", "false");
  await storyGroup.click();

  const card = page.locator(".work-card").first();
  if (await card.count()) {
    await card.click();
    await expect(page.getByRole("button", { name: /close/i })).toBeVisible();
    await page.keyboard.press("Escape");
    await expect(page.getByRole("button", { name: /close/i })).toBeHidden();
  }
});
