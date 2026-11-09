import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { attachRepositoryToContext, rest, textResult } from "./upstreams.js";

const credentials = {
  workerId: z.string().uuid(),
  resumeToken: z.string().min(32).max(256),
};

const workerCapability = z.enum([
  "code_execution",
  "git",
  "browser_automation",
  "screenshot_capture",
  "screen_recording",
  "image_generation",
  "visual_comparison",
]);

export function registerWorkerIdentityTools(server: McpServer) {
  server.registerTool(
    "register_worker",
    {
      description: "Register a persistent agent identity for one project. Handles are unique per project. The resume token is returned once; keep it private and use it with the worker ID for every claim-sensitive operation.",
      inputSchema: {
        projectId: z.string().uuid(),
        handle: z.string().min(3).max(64).regex(/^[a-z0-9][a-z0-9._-]*$/),
        displayName: z.string().min(1).max(120).optional(),
        clientType: z.enum(["codex", "claude", "other"]),
        capabilities: z.array(workerCapability).max(7).default([]).describe("Advertise only capabilities available in this agent session. Queue routing will not assign work requiring an omitted capability."),
      },
    },
    async ({ projectId, handle, displayName, clientType, capabilities }) => textResult(await rest("/rpc/register_agent_worker", {
      method: "POST",
      body: JSON.stringify({
        target_project_id: projectId,
        requested_handle: handle,
        requested_display_name: displayName ?? handle,
        requested_client_type: clientType,
        requested_capabilities: capabilities,
      }),
    })),
  );

  server.registerTool(
    "update_worker_capabilities",
    {
      description: "Update the capabilities currently available to this authenticated worker. Capabilities required by an active claim cannot be removed.",
      inputSchema: { ...credentials, capabilities: z.array(workerCapability).max(7) },
    },
    async ({ workerId, resumeToken, capabilities }) => textResult(await rest("/rpc/update_agent_worker_capabilities", {
      method: "POST",
      body: JSON.stringify({ target_worker_id: workerId, resume_token: resumeToken, requested_capabilities: capabilities }),
    })),
  );

  server.registerTool(
    "resume_worker",
    {
      description: "Resume a previously registered worker identity and verify its private token before continuing the work loop.",
      inputSchema: credentials,
    },
    async ({ workerId, resumeToken }) => textResult(await rest("/rpc/resume_agent_worker", {
      method: "POST",
      body: JSON.stringify({ target_worker_id: workerId, resume_token: resumeToken }),
    })),
  );

  server.registerTool(
    "list_project_workers",
    {
      description: "List registered worker handles, client types, last-seen times, and active claim counts. Private resume tokens are never returned.",
      inputSchema: { projectId: z.string().uuid() },
    },
    async ({ projectId }) => textResult(await rest(`/project_agent_workers?project_id=eq.${projectId}&order=display_name.asc`)),
  );

  server.registerTool(
    "set_work_item_required_capabilities",
    {
      description: "Declare the native capabilities a feature, story, or task requires while its governed story is still unclaimed in Backlog, Analyse, or Plan. Story routing includes inherited feature and child-task requirements.",
      inputSchema: {
        workItemId: z.string().uuid(),
        capabilities: z.array(workerCapability).max(7),
      },
    },
    async ({ workItemId, capabilities }) => textResult(await rest("/rpc/set_work_item_required_capabilities", {
      method: "POST",
      body: JSON.stringify({ target_work_item_id: workItemId, requested_capabilities: capabilities, actor_name: "AI agent" }),
    })),
  );

  server.registerTool(
    "claim_next_ready_work_item",
    {
      description: "Atomically claim one dependency-ready story whose required capabilities are a subset of this authenticated worker's advertised capabilities. Parallel Codex and Claude workers receive different compatible stories.",
      inputSchema: { projectId: z.string().uuid(), ...credentials },
    },
    async ({ projectId, workerId, resumeToken }) => textResult(await attachRepositoryToContext(await rest("/rpc/claim_next_work_package_as_worker", {
      method: "POST",
      body: JSON.stringify({ target_project_id: projectId, target_worker_id: workerId, resume_token: resumeToken }),
    }), projectId)),
  );

  server.registerTool(
    "claim_work_item",
    {
      description: "Atomically claim one specified ready story as this authenticated registered worker.",
      inputSchema: { workItemId: z.string().uuid(), ...credentials },
    },
    async ({ workItemId, workerId, resumeToken }) => textResult(await rest("/rpc/claim_work_item_as_worker", {
      method: "POST",
      body: JSON.stringify({ target_work_item_id: workItemId, target_worker_id: workerId, resume_token: resumeToken }),
    })),
  );

  server.registerTool(
    "move_work_item",
    {
      description: "Move this authenticated worker's claimed card by one allowed governed stage. The registered handle is applied to the audit event automatically.",
      inputSchema: {
        workItemId: z.string().uuid(),
        stage: z.enum(["backlog", "analyse", "plan", "build", "validate", "review", "merge", "post_merge", "done"]),
        summary: z.string().max(500).optional(),
        ...credentials,
      },
    },
    async ({ workItemId, stage, summary, workerId, resumeToken }) => textResult(await rest("/rpc/move_work_item_as_worker", {
      method: "POST",
      body: JSON.stringify({
        target_work_item_id: workItemId,
        target_stage_slug: stage,
        target_worker_id: workerId,
        resume_token: resumeToken,
        event_summary: summary ?? null,
      }),
    })),
  );

  server.registerTool(
    "heartbeat_work_item",
    {
      description: "Renew this authenticated worker's claim lease. Call at least every five minutes during long-running work.",
      inputSchema: { workItemId: z.string().uuid(), ...credentials },
    },
    async ({ workItemId, workerId, resumeToken }) => textResult(await rest("/rpc/heartbeat_work_item_as_worker", {
      method: "POST",
      body: JSON.stringify({ target_work_item_id: workItemId, target_worker_id: workerId, resume_token: resumeToken }),
    })),
  );

  server.registerTool(
    "get_work_item_claim_status",
    {
      description: "Read the registered active worker, claim heartbeat, idle threshold, and human-takeover eligibility.",
      inputSchema: { workItemId: z.string().uuid() },
    },
    async ({ workItemId }) => textResult(await rest("/rpc/get_work_item_claim_status", {
      method: "POST",
      body: JSON.stringify({ target_work_item_id: workItemId }),
    })),
  );

  server.registerTool(
    "block_work_item",
    {
      description: "Block this authenticated worker's claimed item with a concrete reason, then continue to the next ready item.",
      inputSchema: { workItemId: z.string().uuid(), reason: z.string().min(1).max(1000), ...credentials },
    },
    async ({ workItemId, reason, workerId, resumeToken }) => textResult(await rest("/rpc/block_work_item_as_worker", {
      method: "POST",
      body: JSON.stringify({ target_work_item_id: workItemId, target_worker_id: workerId, resume_token: resumeToken, reason }),
    })),
  );

  server.registerTool(
    "release_work_item",
    {
      description: "Release this authenticated worker's claimed item when stopping without a genuine blocker.",
      inputSchema: { workItemId: z.string().uuid(), reason: z.string().max(1000).optional(), ...credentials },
    },
    async ({ workItemId, reason, workerId, resumeToken }) => textResult(await rest("/rpc/release_work_item_as_worker", {
      method: "POST",
      body: JSON.stringify({ target_work_item_id: workItemId, target_worker_id: workerId, resume_token: resumeToken, reason: reason ?? null }),
    })),
  );
}
