import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { rest, textResult } from "./upstreams.js";

export function registerClaimLeaseTools(server: McpServer) {
  server.registerTool(
    "heartbeat_work_item",
    {
      description: "Renew the current worker's claim lease. Call at least every five minutes during long-running work so a human can distinguish active work from an abandoned claim.",
      inputSchema: {
        workItemId: z.string().uuid(),
        agentName: z.string().min(1).max(120),
      },
    },
    async ({ workItemId, agentName }) => textResult(await rest("/rpc/heartbeat_work_item", {
      method: "POST",
      body: JSON.stringify({ target_work_item_id: workItemId, agent_name: agentName }),
    })),
  );

  server.registerTool(
    "get_work_item_claim_status",
    {
      description: "Read the active worker, claim heartbeat, idle threshold, and whether a human-authorized takeover is currently eligible.",
      inputSchema: { workItemId: z.string().uuid() },
    },
    async ({ workItemId }) => textResult(await rest("/rpc/get_work_item_claim_status", {
      method: "POST",
      body: JSON.stringify({ target_work_item_id: workItemId }),
    })),
  );
}
