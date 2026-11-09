import { readFile } from "node:fs/promises";

// These are architectural guardrails, not targets. Files near a limit should
// be split by responsibility before new behaviour is added.
const limits = new Map([
  ["apps/mcp/src/server.ts", 1600],
  ["apps/web/src/styles.css", 750],
  ["apps/web/src/datashow.css", 500],
  ["apps/web/src/components/ItemDrawer.tsx", 650],
]);

let failed = false;
for (const [filename, maximum] of limits) {
  const source = await readFile(new URL(`../${filename}`, import.meta.url), "utf8");
  const lines = source.split("\n").length;
  const status = lines <= maximum ? "ok" : "over limit";
  console.log(`${status.padEnd(10)} ${String(lines).padStart(4)} / ${maximum}  ${filename}`);
  failed ||= lines > maximum;
}

if (failed) {
  console.error("Source limit exceeded. Extract a cohesive module instead of increasing the budget.");
  process.exitCode = 1;
}
