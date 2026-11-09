import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const designSystem = readFileSync(new URL("./datashow.css", import.meta.url), "utf8");
const applicationStyles = readFileSync(new URL("./styles.css", import.meta.url), "utf8");

describe("typographic hierarchy", () => {
  it("defines shared page and section title roles", () => {
    expect(designSystem).toContain("--fz-page-title:");
    expect(designSystem).toContain("--fz-section-title:");
  });

  it("uses the same page-title role on every page header", () => {
    expect(applicationStyles).toMatch(/\.page-head h1[^}]+font-size:\s*var\(--fz-page-title\)/s);
    expect(applicationStyles).toMatch(/\.board-head h1[^}]+font-size:\s*var\(--fz-page-title\)/s);
  });

  it("uses the canonical section-title role", () => {
    expect(applicationStyles).toMatch(/\.dashboard-section-head h2[^}]+font-size:\s*var\(--fz-section-title\)/s);
  });
});
