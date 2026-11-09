import assert from "node:assert/strict";
import test from "node:test";
import { formatGreeting } from "./greeting.mjs";

test("formats a supplied name", () => {
  assert.equal(formatGreeting("Codex"), "Hello, Codex!");
});

test("uses world when the supplied name is blank", () => {
  assert.equal(formatGreeting("  "), "Hello, world!");
});
