import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { rest, textResult } from "./upstreams.js";

export function registerOwnershipTools(server: McpServer) {
  server.registerTool(
    "set_work_item_owner",
    {
      description: "Assign or clear the durable owner of a feature, story, or task. Ownership survives claim release and is distinct from the active worker.",
      inputSchema: {
        workItemId: z.string().uuid(),
        owner: z.string().min(1).max(120).nullable(),
        actor: z.string().min(1).max(120).default("AI agent"),
      },
    },
    async ({ workItemId, owner, actor }) => textResult(await rest("/rpc/set_work_item_owner", {
      method: "POST",
      body: JSON.stringify({ target_work_item_id: workItemId, owner_name: owner, actor_name: actor }),
    })),
  );

  server.registerTool(
    "list_project_owners",
    {
      description: "List project owners with their owned, running, blocked, and completed work counts.",
      inputSchema: { projectId: z.string().uuid() },
    },
    async ({ projectId }) => textResult(await rest(`/project_owner_summary?project_id=eq.${projectId}&order=owner.asc`)),
  );
}
