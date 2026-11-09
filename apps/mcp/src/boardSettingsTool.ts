import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { rest, textResult } from "./upstreams.js";

export function registerBoardSettingsTool(server: McpServer) {
  server.registerTool(
    "update_board_stage_settings",
    {
      description: "Update a project's visible board bucket, WIP limit, purpose, responsible actor, and deterministic exit criteria for one governed stage. Stage order and allowed transitions remain locked.",
      inputSchema: {
        stageId: z.string().uuid(),
        bucketTitle: z.string().min(1).max(60),
        purpose: z.string().max(1000).default(""),
        responsibleActor: z.string().min(1).max(120),
        wipLimit: z.number().int().min(1).max(100).nullable().default(null),
        exitCriteria: z.array(z.string().min(1).max(500)).max(30),
        actor: z.string().min(1).max(120).default("AI agent"),
      },
    },
    async ({ stageId, bucketTitle, purpose, responsibleActor, wipLimit, exitCriteria, actor }) => textResult(await rest("/rpc/update_board_stage_settings", {
      method: "POST",
      body: JSON.stringify({
        target_stage_id: stageId,
        stage_bucket_title: bucketTitle,
        stage_purpose: purpose,
        stage_responsible_actor: responsibleActor,
        stage_wip_limit: wipLimit,
        stage_exit_criteria: exitCriteria,
        actor_name: actor,
      }),
    })),
  );
}
