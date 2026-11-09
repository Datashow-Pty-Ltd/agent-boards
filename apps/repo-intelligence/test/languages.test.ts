import assert from "node:assert/strict";
import test from "node:test";

import { detectLanguage, extractTypeScriptIntelligence, isGeneratedPath } from "../src/languages.js";

test("detects supported source languages case-insensitively", () => {
  assert.equal(detectLanguage("src/Card.TSX"), "tsx");
  assert.equal(detectLanguage("database/schema.sql"), "sql");
  assert.equal(detectLanguage("LICENSE"), "text");
});

test("excludes generated and vendored paths", () => {
  assert.equal(isGeneratedPath("src/index.ts"), false);
  assert.equal(isGeneratedPath("packages/client/dist/index.js"), true);
  assert.equal(isGeneratedPath("vendor/library.ts"), true);
  assert.equal(isGeneratedPath("public/app.min.js"), true);
});

test("extracts syntax-precision declarations and module edges", () => {
  const result = extractTypeScriptIntelligence(
    'import { value } from "./source.js";\nexport class Service { run() { return value; } }\nexport { other } from "./other.js";',
    "typescript",
  );

  assert.equal(result.parseErrors, 0);
  assert.deepEqual(result.edges, [
    { kind: "import", target: "./source.js" },
    { kind: "export", target: "./other.js" },
  ]);
  assert.ok(result.symbols.some((symbol) => symbol.name === "Service" && symbol.kind === "class" && symbol.exported));
  assert.ok(result.symbols.some((symbol) => symbol.name === "run" && symbol.kind === "method" && symbol.containerName === "Service"));
});
