import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { summarizeBoard } from "../src/boardSummary.ts";

const read = (path) => readFile(new URL(path, import.meta.url), "utf8");
const [server, upstreams, stack] = await Promise.all([
  read("../src/server.ts"),
  read("../src/upstreams.ts"),
  read("../../../scripts/stack.sh"),
]);

const board = () => ({
  project: { id: "p1", project_key: "AB", name: "Demo", status: "active", description: "long" },
  repository: null,
  board: { id: "b1", name: "Delivery" },
  stages: [
    { id: "s-build", slug: "build", title: "Build", position: 3, responsible_actor: "Implementation agent", purpose: "long" },
    { id: "s-review", slug: "review", title: "Review", position: 5, responsible_actor: "Reviewer" },
  ],
  items: [
    { id: "i1", item_key: "AB-1", kind: "story", title: "One", stage_id: "s-review", description: "big body", acceptance_criteria: [{ statement: "x" }], assignee: "alice", claim_heartbeat_at: "2026-11-11T00:00:00Z", required_worker_capabilities: ["git"] },
    { id: "i2", item_key: "AB-2", kind: "story", title: "Two", stage_id: "s-gone" },
  ],
  dependencies: [{ work_item_id: "i2", depends_on_work_item_id: "i1", created_at: "t" }],
  // Newest first, as get_board requests it.
  evidence: [
    { work_item_id: "i1", evidence_type: "test", outcome: "passed", revision: "new", summary: "s" },
    { work_item_id: "i1", evidence_type: "test", outcome: "failed", revision: "old", summary: "s" },
    { work_item_id: "i1", evidence_type: "review", outcome: "passed", revision: "new", summary: "s" },
  ],
  visualAssets: [{ id: "a1" }],
  metrics: [{ total_items: 2 }],
  deliveryStatuses: [{ work_item_id: "i1", delivery_complete: false, visual_compliant: true, stage_slug: "review" }],
  visualCompliance: [{ work_item_id: "i1", compliant: false, failed_screen_count: 2, remediation_work_item_id: null, compliance: { requirements: [] } }],
});

test("board summary keeps routing fields, latest evidence per type and statuses", () => {
  const summary = summarizeBoard(board());
  const [one, two] = summary.items;
  assert.equal(summary.detail, "summary");
  assert.equal(one.stage, "review");
  assert.equal(two.stage, null);
  assert.deepEqual(one.latest_evidence, { test: { outcome: "passed", revision: "new" }, review: { outcome: "passed", revision: "new" } });
  assert.deepEqual(two.latest_evidence, {});
  assert.equal(one.assignee, "alice");
  assert.equal(one.claim_heartbeat_at, "2026-11-11T00:00:00Z");
  assert.deepEqual(one.required_worker_capabilities, ["git"]);
  assert.equal(one.delivery_complete, false);
  assert.equal(one.visual_compliant, true);
  assert.deepEqual(one.visual_compliance, { compliant: false, failed_screen_count: 2, remediation_work_item_id: null });
  assert.equal(summary.stages[1].responsible_actor, "Reviewer");
  assert.deepEqual(summary.dependencies, [{ work_item_id: "i2", depends_on_work_item_id: "i1" }]);
});

test("board summary omits bodies and bulky collections", () => {
  const summary = summarizeBoard(board());
  const [one] = summary.items;
  assert.equal("description" in one, false);
  assert.equal("acceptance_criteria" in one, false);
  assert.equal("purpose" in summary.stages[0], false);
  assert.equal("description" in summary.project, false);
  for (const key of ["evidence", "visualAssets", "deliveryStatuses", "visualCompliance"]) assert.equal(key in summary, false);
});

test("create_backlog_item returns the card after every follow-up update", () => {
  for (const rpc of ["set_work_item_required_capabilities", "set_work_item_owner", "set_interaction_evidence_requirement", "set_design_card", "set_visual_evidence_requirement"]) {
    assert.match(server, new RegExp(`created = await rest\\("/rpc/${rpc}"`));
  }
  const handler = server.slice(server.indexOf('"create_backlog_item"'), server.indexOf('"update_work_item"'));
  assert.equal(handler.match(/return textResult\(/g)?.length, 1);
});

test("get_board defaults to summary and MCP results are compact JSON", () => {
  assert.match(server, /detail: z\.enum\(\["summary", "full"\]\)\.default\("summary"\)/);
  assert.match(server, /detail === "full" \? full : summarizeBoard\(full\)/);
  assert.match(upstreams, /text: JSON\.stringify\(value\) \}/);
});

test("Apple stack binds loopback, refuses a busy port and can use the GitHub CLI token", () => {
  assert.match(stack, /HOST_PORT=\$\{AGENT_BOARDS_PORT:-4747\}/);
  assert.match(stack, /--publish "\$\{BIND_ADDRESS\}:\$\{HOST_PORT\}:8080"/);
  assert.match(stack, /check_port_free\r?\n\s+resolve_github_token/);
  assert.match(stack, /AGENT_BOARDS_USE_GH_TOKEN:-1/);
  assert.doesNotMatch(stack, /\. "\$ROOT_DIR\/\.env"/);
  assert.doesNotMatch(stack, /echo[^\n]*\$\{?GITHUB_TOKEN/);
});
