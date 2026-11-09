import assert from "node:assert/strict";
import test from "node:test";

import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";

const gatewayUrl = process.env.AGENT_BOARDS_URL ?? "http://127.0.0.1:4173";

test("OpenResty exposes a usable Agent Boards MCP endpoint", async () => {
  const health = await fetch(`${gatewayUrl}/health`);
  assert.equal(health.status, 200, "gateway health endpoint should respond");

  const client = new Client({ name: "agent-boards-release-smoke", version: "1.0.0" });
  const transport = new StreamableHTTPClientTransport(new URL(`${gatewayUrl}/mcp`));

  try {
    await client.connect(transport);

    const instructions = client.getInstructions();
    assert.ok(instructions, "server should provide focused worker instructions");
    assert.ok(instructions.length < 2_500, "server instructions should stay focused and context-efficient");
    assert.match(instructions, /claim_next_ready_work_item/);

    const { tools } = await client.listTools();
    const toolNames = new Set(tools.map((tool) => tool.name));
    for (const requiredTool of ["list_projects", "get_board", "claim_next_ready_work_item", "move_work_item"]) {
      assert.ok(toolNames.has(requiredTool), `missing required MCP tool: ${requiredTool}`);
    }

    const projects = await client.callTool({
      name: "list_projects",
      arguments: { includeArchived: false },
    });
    assert.equal(projects.isError, undefined, "list_projects should not return an MCP error");
    assert.ok(Array.isArray(projects.content), "tool result should use MCP content blocks");
    assert.ok(projects.content.some((block) => block.type === "text"), "tool result should include text content");
  } finally {
    await client.close();
  }
});
