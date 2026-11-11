import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");
const [server, upstreams, summary, stack] = await Promise.all([
  read("../src/server.ts"),
  read("../src/upstreams.ts"),
  read("../src/boardSummary.ts"),
  read("../../../scripts/stack.sh"),
]);

test("create_backlog_item returns the card after capability and flag updates", () => {
  assert.match(server, /created = await rest\("\/rpc\/set_work_item_required_capabilities"/);
  assert.match(server, /created = await rest\("\/rpc\/set_interaction_evidence_requirement"/);
});

test("get_board defaults to a compact summary and keeps a full mode", () => {
  assert.match(server, /detail: z\.enum\(\["summary", "full"\]\)\.default\("summary"\)/);
  assert.match(server, /detail === "full" \? full : summarizeBoard\(full\)/);
  assert.match(summary, /latest_evidence/);
  assert.doesNotMatch(summary, /"description"|"acceptance_criteria"/);
  assert.match(upstreams, /text: JSON\.stringify\(value\) \}/);
});

test("Apple stack binds loopback, refuses a busy port and can use the GitHub CLI token", () => {
  assert.match(stack, /HOST_PORT=\$\{AGENT_BOARDS_PORT:-4747\}/);
  assert.match(stack, /--publish "\$\{BIND_ADDRESS\}:\$\{HOST_PORT\}:8080"/);
  assert.match(stack, /check_port_free\n\s+resolve_github_token/);
  assert.match(stack, /gh auth token/);
  assert.doesNotMatch(stack, /echo[^\n]*\$GITHUB_TOKEN/);
});
