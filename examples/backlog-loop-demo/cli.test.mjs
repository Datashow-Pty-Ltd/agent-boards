import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import test from "node:test";

test("prints the exact greeting", () => {
  const output = execFileSync(process.execPath, ["greet.mjs", "Codex"], {
    cwd: new URL(".", import.meta.url),
    encoding: "utf8",
  });

  assert.equal(output, "Hello, Codex!\n");
});
