import assert from "node:assert/strict";
import test from "node:test";

import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";

const gatewayUrl = process.env.AGENT_BOARDS_URL ?? "http://127.0.0.1:4173";

async function api(path, init = {}) {
  const response = await fetch(`${gatewayUrl}/api${path}`, {
    ...init,
    headers: { "Content-Type": "application/json", Prefer: "return=representation", ...init.headers },
  });
  if (!response.ok) assert.fail(`${init.method ?? "GET"} ${path} failed: ${response.status} ${await response.text()}`);
  return response.status === 204 ? null : response.json();
}

function resultJson(result) {
  const text = result.content?.find((entry) => entry.type === "text")?.text;
  assert.ok(text, "MCP result should contain JSON text");
  return JSON.parse(text);
}

test("three MCP workers claim and move three different stories concurrently", async () => {
  const suffix = `${Date.now()}`.slice(-8);
  const projectKey = `MW${suffix}`;
  const [project] = await api("/rpc/create_project", {
    method: "POST",
    body: JSON.stringify({
      project_name: "Multi-worker smoke test",
      project_key: projectKey,
      project_description: "Disposable concurrent MCP claim test.",
      project_owner: "Release test",
    }),
  });
  const workerNames = ["Codex Alpha", "Claude Beta", "Codex Gamma"];
  const clients = [];

  try {
    const [board] = await api(`/boards?project_id=eq.${project.id}&select=id`);
    for (let index = 0; index < workerNames.length; index += 1) {
      await api("/rpc/create_backlog_item", {
        method: "POST",
        body: JSON.stringify({
          target_project_id: project.id,
          item_title: `Concurrent story ${index + 1}`,
          item_description: "A ready story used to prove parallel claims.",
          item_kind: "story",
          item_priority: "high",
          parent_work_item_id: null,
          item_assignee: null,
          item_acceptance_criteria: [{
            statement: "The story is claimed by exactly one worker.",
            verification_method: "database_assertion",
            verification_ref: "api.work_items.assignee",
            expected_result: "Three concurrent claims have three distinct work item IDs.",
          }],
          item_invariants: ["A work item has at most one active worker."],
          actor_name: "Release test",
        }),
      });
    }

    for (const workerName of workerNames) {
      const client = new Client({ name: workerName, version: "1.0.0" });
      await client.connect(new StreamableHTTPClientTransport(new URL(`${gatewayUrl}/mcp`)));
      clients.push(client);
    }

    const claims = await Promise.all(clients.map((client, index) => client.callTool({
      name: "claim_next_ready_work_item",
      arguments: { projectId: project.id, agentName: workerNames[index] },
    })));
    const packages = claims.map(resultJson);
    const stories = packages.map((payload) => payload.work_package.story);

    assert.equal(new Set(stories.map((story) => story.id)).size, 3, "every worker should receive a different story");
    stories.forEach((story, index) => {
      assert.equal(story.owner, workerNames[index], "first claim should assign durable ownership");
      assert.equal(story.assignee, workerNames[index], "claim should record the active worker");
    });

    await Promise.all(clients.map((client, index) => client.callTool({
      name: "move_work_item",
      arguments: { workItemId: stories[index].id, stage: "analyse", actor: workerNames[index] },
    })));

    const moved = await api(`/work_items?project_id=eq.${project.id}&kind=eq.story&select=id,owner,assignee,stage_id`);
    const stages = await api(`/board_stages?board_id=eq.${board.id}&slug=eq.analyse&select=id`);
    assert.equal(moved.length, 3);
    assert.ok(moved.every((story) => story.stage_id === stages[0].id), "all three cards should move independently to Analyse");
  } finally {
    await Promise.allSettled(clients.map((client) => client.close()));
    await api(`/projects?id=eq.${project.id}`, { method: "DELETE" });
  }
});
