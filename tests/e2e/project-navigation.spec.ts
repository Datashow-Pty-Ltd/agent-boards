import { expect, test } from "@playwright/test";

test("opens a project board and supports keyboard drawer dismissal", async ({ page }) => {
  await page.addInitScript(() => {
    window.localStorage.removeItem("agent-boards:first-run-tour:v1");
  });
  await page.goto("/");
  await expect(page.getByRole("heading", { name: "The board is the source of truth" })).toBeVisible();
  const tourClose = page.locator(".tour-modal .mantine-Modal-close");
  await expect(tourClose).not.toBeFocused();
  expect(await tourClose.evaluate((element) => element.matches(":focus-visible"))).toBe(false);
  await page.keyboard.press("Tab");
  await expect(tourClose).toBeFocused();
  expect(await tourClose.evaluate((element) => element.matches(":focus-visible"))).toBe(true);
  for (let step = 0; step < 4; step += 1) await page.getByRole("button", { name: "Next" }).click();
  await expect(page.getByRole("heading", { name: "Connect your coding agent" })).toBeVisible();
  await expect(page.getByText("Streamable HTTP MCP endpoint at /mcp", { exact: false })).toBeVisible();
  await expect(page.getByRole("button", { name: "Copy instruction" })).toBeVisible();
  await page.setViewportSize({ width: 390, height: 700 });
  const progressRows = await page.locator(".tour-progress i").evaluateAll((steps) =>
    new Set(steps.map((step) => Math.round(step.getBoundingClientRect().top))).size,
  );
  expect(progressRows).toBe(1);
  await expect(page.getByRole("button", { name: "Copy instruction" })).toBeVisible();
  await page.getByRole("button", { name: "Back" }).click();
  await expect(page.getByRole("heading", { name: "Evidence closes the loop" })).toBeVisible();
  await page.getByRole("button", { name: "Next" }).click();
  await expect(page.getByRole("button", { name: "Start using Agent Boards" })).toBeVisible();
  await page.getByRole("button", { name: "Skip tour" }).click();
  await page.setViewportSize({ width: 1280, height: 720 });
  await expect(page.getByRole("heading", { name: "Project delivery" })).toBeVisible();

  const project = page.locator(".project-card").filter({ hasText: "Agent Boards Demo" });
  await expect(project).toBeVisible();
  await expect(project.getByText("Agent Boards Demo", { exact: true })).toBeVisible();
  await project.click();

  await expect(page.getByRole("navigation", { name: "Project views" })).toBeVisible();
  await expect(page.getByText("Usage not reported", { exact: true })).toBeVisible();
  await expect(page.getByText("No tracked sessions", { exact: true })).toBeVisible();
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
