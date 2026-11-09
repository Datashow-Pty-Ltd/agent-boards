import express from "express";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { z } from "zod";
import {
  listServiceCapabilities,
  readServiceCapability,
  serviceCapabilityIds,
} from "./serviceCapabilities.js";
import {
  attachRepositoryToContext,
  getProjectRepository,
  intelligence,
  rest,
  textResult,
} from "./upstreams.js";
import {
  deleteStoredMedia,
  probeVideoDuration,
  storeMedia,
  uploadDirectory,
} from "./media.js";
import { serverInstructions } from "./serverInstructions.js";
import { registerBoardSettingsTool } from "./boardSettingsTool.js";

const port = Number(process.env.PORT ?? 8080);
const app = express();
app.use(express.json({ limit: "70mb" }));

const acceptanceCriterionSchema = z.object({
  statement: z.string().min(1).max(1000),
  verificationMethod: z.enum(["automated_test", "command", "http_assertion", "database_assertion", "visual_baseline"]),
  verificationRef: z.string().min(1).max(2000),
  expectedResult: z.string().min(1).max(2000),
});

const visualAssetTypeSchema = z.enum(["reference", "mockup", "wireframe", "implementation_screenshot", "visual_validation", "visual_diff", "validation_recording"]);
const imageSourceSchema = z.string().min(1).max(11_000_000).refine(
  (value) => /^https?:\/\//.test(value) || /^data:image\//.test(value),
  "Use an HTTP(S) image URL or a data:image URI.",
);
const mediaSourceSchema = z.string().min(1).max(11_000_000).refine(
  (value) => /^https?:\/\//.test(value) || /^data:(image|video)\//.test(value) || /^\/uploads\/[A-Za-z0-9._-]+$/.test(value),
  "Use an HTTP(S) media URL, a managed /uploads URL, or a data:image/data:video URI.",
);
const mediaMimeTypeSchema = z.enum(["video/webm", "video/mp4", "video/quicktime"]);
const repositoryRevisionSchema = z.string().min(1).max(240).regex(/^[A-Za-z0-9._/@:+-]+$/);
const repositoryMapTypeSchema = z.enum(["architecture", "domain", "dependency", "quality", "change_impact"]);
const visualMeasurementSchema = z.object({
  surface: z.enum(["typography", "geometry", "spacing", "color"]),
  element: z.string().min(1).max(240),
  property: z.string().min(1).max(120),
  referenceValue: z.union([z.string(), z.number()]),
  implementationValue: z.union([z.string(), z.number()]),
  unit: z.string().min(1).max(40),
  tolerance: z.number().nonnegative(),
  delta: z.number().nonnegative(),
  severity: z.enum(["P0", "P1", "P2", "P3"]),
  method: z.string().min(1).max(500),
});
const visualCritiqueFindingSchema = z.object({
  severity: z.enum(["P0", "P1", "P2", "P3"]),
  summary: z.string().min(1).max(1000),
  resolved: z.boolean(),
  element: z.string().max(240).optional(),
  property: z.string().max(120).optional(),
  recommendation: z.string().max(2000).optional(),
});

function buildServer() {
  const server = new McpServer(
    { name: "agent-boards", version: "0.1.0" },
    {
      instructions: serverInstructions,
    },
  );

  for (const descriptor of listServiceCapabilities()) {
    server.registerResource(
      `agent-boards-${descriptor.id}`,
      descriptor.resourceUri,
      {
        title: descriptor.title,
        description: descriptor.description,
        mimeType: "text/markdown",
      },
      async () => ({
        contents: [{
          uri: descriptor.resourceUri,
          mimeType: "text/markdown",
          text: (await readServiceCapability(descriptor.id)).instructions,
        }],
      }),
    );
  }

  registerBoardSettingsTool(server);

  server.registerTool(
    "list_service_capabilities",
    {
      description: "List the portable workflow contracts supplied by Agent Boards. These describe how the connected agent must use its own native capabilities safely within board invariants and gates.",
      inputSchema: {},
    },
    async () => textResult(listServiceCapabilities()),
  );

  server.registerTool(
    "get_service_capability",
    {
      description: "Read a built-in Agent Boards workflow contract. Call this for every service_capability listed in a claimed work package before performing that work.",
      inputSchema: {
        capability: z.enum(serviceCapabilityIds),
      },
    },
    async ({ capability }) => textResult(await readServiceCapability(capability)),
  );

  server.registerTool(
    "list_projects",
    {
      description: "List active Agent Boards projects and their delivery metrics. Archived projects are omitted unless explicitly requested.",
      inputSchema: { includeArchived: z.boolean().default(false) },
    },
    async ({ includeArchived }) => textResult(await rest(`/project_summary?${includeArchived ? "" : "status=neq.archived&"}order=updated_at.desc`)),
  );

  server.registerTool(
    "create_project",
    {
      description: "Create a project with the standard Agent Boards delivery workflow.",
      inputSchema: {
        name: z.string().min(1).max(160),
        key: z.string().min(2).max(12).regex(/^[A-Za-z][A-Za-z0-9-]*$/),
        description: z.string().max(2000).optional(),
        owner: z.string().max(120).optional(),
        repositoryUrl: z.string().url().max(2000).optional(),
        defaultBranch: z.string().min(1).max(240).default("main"),
      },
    },
    async ({ name, key, description, owner, repositoryUrl, defaultBranch }) => {
      const projects = await rest(repositoryUrl ? "/rpc/create_project_with_repository" : "/rpc/create_project", {
          method: "POST",
          body: JSON.stringify({
            project_name: name,
            project_key: key.toUpperCase(),
            project_description: description ?? "",
            project_owner: owner ?? "Unassigned",
            ...(repositoryUrl ? {
              repository_url: repositoryUrl,
              repository_default_branch: defaultBranch,
              actor_name: "AI agent",
            } : {}),
          }),
        });
      const project = Array.isArray(projects) ? projects[0] : null;
      const repository = repositoryUrl && typeof project?.id === "string"
        ? await getProjectRepository(project.id)
        : null;
      return textResult({ projects, repository });
    },
  );

  server.registerTool(
    "get_project_repository",
    {
      description: "Get the source repository durably linked to a project. Returns null when the project is not linked to a repository.",
      inputSchema: { projectId: z.string().uuid() },
    },
    async ({ projectId }) => textResult(await getProjectRepository(projectId)),
  );

  server.registerTool(
    "archive_project",
    {
      description: "Archive a project while preserving its board and record. Archived project work is read-only and cannot be claimed until restored.",
      inputSchema: {
        projectId: z.string().uuid(),
        actor: z.string().min(1).max(120).default("AI agent"),
      },
    },
    async ({ projectId, actor }) => textResult(await rest("/rpc/archive_project", {
      method: "POST",
      body: JSON.stringify({ target_project_id: projectId, actor_name: actor }),
    })),
  );

  server.registerTool(
    "restore_project",
    {
      description: "Restore an archived project to its previous status so its work can continue.",
      inputSchema: {
        projectId: z.string().uuid(),
        actor: z.string().min(1).max(120).default("AI agent"),
      },
    },
    async ({ projectId, actor }) => textResult(await rest("/rpc/restore_project", {
      method: "POST",
      body: JSON.stringify({ target_project_id: projectId, actor_name: actor }),
    })),
  );

  server.registerTool(
    "set_project_repository",
    {
      description: "Link or change the real source repository associated with a project. The association is shared by the UI, REST API, and agent work packages.",
      inputSchema: {
        projectId: z.string().uuid(),
        repositoryUrl: z.string().url().max(2000),
        defaultBranch: z.string().min(1).max(240).default("main"),
        actor: z.string().min(1).max(120).default("AI agent"),
      },
    },
    async ({ projectId, repositoryUrl, defaultBranch, actor }) => textResult(await rest("/rpc/set_project_repository", {
      method: "POST",
      body: JSON.stringify({
        target_project_id: projectId,
        target_repository_url: repositoryUrl,
        target_default_branch: defaultBranch,
        actor_name: actor,
      }),
    })),
  );

  server.registerTool(
    "remove_project_repository",
    {
      description: "Remove a project's source repository association when it is no longer valid.",
      inputSchema: {
        projectId: z.string().uuid(),
        actor: z.string().min(1).max(120).default("AI agent"),
      },
    },
    async ({ projectId, actor }) => textResult(await rest("/rpc/remove_project_repository", {
      method: "POST",
      body: JSON.stringify({ target_project_id: projectId, actor_name: actor }),
    })),
  );

  server.registerTool(
    "request_repository_index",
    {
      description: "Queue a read-only repository intelligence snapshot for an exact revision. Poll the returned job before querying it.",
      inputSchema: {
        projectId: z.string().uuid(),
        revision: repositoryRevisionSchema.optional(),
        actor: z.string().min(1).max(120).default("AI agent"),
      },
    },
    async ({ projectId, revision, actor }) => textResult(await intelligence("/v1/index", {
      method: "POST",
      body: JSON.stringify({ projectId, revision, actor }),
    })),
  );

  server.registerTool(
    "get_repository_index_job",
    {
      description: "Get the durable status of a repository indexing job.",
      inputSchema: { jobId: z.string().uuid() },
    },
    async ({ jobId }) => textResult(await intelligence(`/v1/jobs/${encodeURIComponent(jobId)}`)),
  );

  server.registerTool(
    "get_repository_snapshot",
    {
      description: "Get the latest ready repository snapshot, or the snapshot for an exact revision. The returned commit SHA is the provenance boundary for later evidence.",
      inputSchema: { projectId: z.string().uuid(), revision: repositoryRevisionSchema.optional() },
    },
    async ({ projectId, revision }) => textResult(await intelligence(
      `/v1/projects/${encodeURIComponent(projectId)}/snapshot${revision ? `?revision=${encodeURIComponent(revision)}` : ""}`,
    )),
  );

  server.registerTool(
    "search_repository",
    {
      description: "Search a revision-pinned repository snapshot without checking out or modifying the project.",
      inputSchema: {
        projectId: z.string().uuid(),
        query: z.string().min(1).max(500),
        revision: repositoryRevisionSchema.optional(),
        regex: z.boolean().default(false),
        maxResults: z.number().int().min(1).max(500).default(50),
      },
    },
    async ({ projectId, query, revision, regex, maxResults }) => textResult(await intelligence("/v1/search", {
      method: "POST",
      body: JSON.stringify({ projectId, query, revision, regex, maxResults }),
    })),
  );

  server.registerTool(
    "read_repository_file",
    {
      description: "Read one file from a ready, exact-revision repository snapshot.",
      inputSchema: {
        projectId: z.string().uuid(),
        path: z.string().min(1).max(2000),
        revision: repositoryRevisionSchema.optional(),
      },
    },
    async ({ projectId, path: filePath, revision }) => {
      const snapshot = await intelligence(`/v1/projects/${encodeURIComponent(projectId)}/snapshot${revision ? `?revision=${encodeURIComponent(revision)}` : ""}`) as Record<string, unknown>;
      return textResult(await intelligence(`/v1/snapshots/${encodeURIComponent(String(snapshot.id))}/file?path=${encodeURIComponent(filePath)}`));
    },
  );

  server.registerTool(
    "list_repository_symbols",
    {
      description: "List syntax-derived declarations in a repository snapshot. These are deterministic syntax facts, not compiler-resolved symbols.",
      inputSchema: {
        projectId: z.string().uuid(),
        revision: repositoryRevisionSchema.optional(),
        query: z.string().max(240).optional(),
        path: z.string().max(2000).optional(),
        limit: z.number().int().min(1).max(500).default(100),
      },
    },
    async ({ projectId, revision, query, path: filePath, limit }) => {
      const snapshot = await intelligence(`/v1/projects/${encodeURIComponent(projectId)}/snapshot${revision ? `?revision=${encodeURIComponent(revision)}` : ""}`) as Record<string, unknown>;
      const params = new URLSearchParams({ limit: String(limit) });
      if (query) params.set("query", query);
      if (filePath) params.set("path", filePath);
      const symbols = await intelligence(`/v1/snapshots/${encodeURIComponent(String(snapshot.id))}/symbols?${params.toString()}`);
      return textResult({ snapshot, symbols });
    },
  );

  server.registerTool(
    "get_repository_graph",
    {
      description: "Get syntax-derived import and export edges for a repository snapshot, optionally scoped to one source path.",
      inputSchema: {
        projectId: z.string().uuid(),
        revision: repositoryRevisionSchema.optional(),
        path: z.string().max(2000).optional(),
      },
    },
    async ({ projectId, revision, path: filePath }) => {
      const snapshot = await intelligence(`/v1/projects/${encodeURIComponent(projectId)}/snapshot${revision ? `?revision=${encodeURIComponent(revision)}` : ""}`) as Record<string, unknown>;
      return textResult(await intelligence(`/v1/snapshots/${encodeURIComponent(String(snapshot.id))}/graph${filePath ? `?path=${encodeURIComponent(filePath)}` : ""}`));
    },
  );

  server.registerTool(
    "compare_repository_revisions",
    {
      description: "Compare two repository revisions and return exact resolved commits plus changed paths and diff statistics.",
      inputSchema: {
        projectId: z.string().uuid(),
        baseRevision: repositoryRevisionSchema,
        headRevision: repositoryRevisionSchema,
      },
    },
    async ({ projectId, baseRevision, headRevision }) => textResult(await intelligence("/v1/compare", {
      method: "POST",
      body: JSON.stringify({ projectId, baseRevision, headRevision }),
    })),
  );

  server.registerTool(
    "get_repository_quality_checks",
    {
      description: "List quality commands discovered from repository configuration. Discovery does not mean a command has passed; the agent or CI must execute it.",
      inputSchema: { projectId: z.string().uuid(), revision: repositoryRevisionSchema.optional() },
    },
    async ({ projectId, revision }) => {
      const snapshot = await intelligence(`/v1/projects/${encodeURIComponent(projectId)}/snapshot${revision ? `?revision=${encodeURIComponent(revision)}` : ""}`) as Record<string, unknown>;
      const checks = await intelligence(`/v1/snapshots/${encodeURIComponent(String(snapshot.id))}/quality-checks`);
      return textResult({ snapshot, checks });
    },
  );

  server.registerTool(
    "list_repository_maps",
    {
      description: "List reusable, revision-pinned repository maps with source citations.",
      inputSchema: { projectId: z.string().uuid(), revision: repositoryRevisionSchema.optional() },
    },
    async ({ projectId, revision }) => textResult(await intelligence(
      `/v1/projects/${encodeURIComponent(projectId)}/maps${revision ? `?revision=${encodeURIComponent(revision)}` : ""}`,
    )),
  );

  server.registerTool(
    "upsert_repository_map",
    {
      description: "Persist a reusable repository map for an exact snapshot. Every map must include inspectable path and line citations.",
      inputSchema: {
        projectId: z.string().uuid(),
        mapKey: z.string().min(1).max(120).regex(/^[a-z0-9]+(?:-[a-z0-9]+)*$/),
        revision: repositoryRevisionSchema.optional(),
        mapType: repositoryMapTypeSchema,
        title: z.string().min(1).max(240),
        content: z.record(z.string(), z.unknown()),
        citations: z.array(z.object({
          path: z.string().min(1).max(2000),
          startLine: z.number().int().positive().optional(),
          endLine: z.number().int().positive().optional(),
          symbol: z.string().max(500).optional(),
        })).min(1).max(1000),
        actor: z.string().min(1).max(120).default("AI agent"),
      },
    },
    async ({ projectId, mapKey, revision, mapType, title, content, citations, actor }) => textResult(await intelligence(
      `/v1/projects/${encodeURIComponent(projectId)}/maps/${encodeURIComponent(mapKey)}`,
      { method: "PUT", body: JSON.stringify({ revision, mapType, title, content, citations, actor }) },
    )),
  );

  server.registerTool(
    "get_board",
    {
      description: "Get a project board, stages, cards, dependencies, and current telemetry.",
      inputSchema: { projectId: z.string().uuid() },
    },
    async ({ projectId }) => {
      const projects = (await rest(`/projects?id=eq.${projectId}`)) as Record<string, unknown>[];
      const boards = (await rest(`/boards?project_id=eq.${projectId}`)) as Record<string, unknown>[];
      const boardId = boards[0]?.id;
      const [stages, items, metrics, repository, deliveryStatuses, visualCompliance] = await Promise.all([
        boardId ? rest(`/board_stages?board_id=eq.${boardId}&order=position.asc`) : [],
        boardId ? rest(`/work_items?board_id=eq.${boardId}&archived_at=is.null&order=position.asc`) : [],
        rest(`/project_summary?project_id=eq.${projectId}`),
        getProjectRepository(projectId),
        rest(`/work_item_delivery_status?project_id=eq.${projectId}`),
        rest(`/visual_story_compliance?project_id=eq.${projectId}`),
      ]);
      const itemRows = items as Record<string, unknown>[];
      const itemIds = itemRows.map((item) => item.id).join(",");
      const [dependencies, evidence, visualAssets] = itemRows.length
        ? await Promise.all([
          rest(`/work_item_dependencies?work_item_id=in.(${itemIds})`),
          rest(`/work_item_evidence?work_item_id=in.(${itemIds})&order=created_at.desc`),
          rest(`/work_item_assets?project_id=eq.${projectId}&order=is_primary.desc,created_at.desc`),
        ])
        : [[], [], []];
      return textResult({ project: projects[0], repository, board: boards[0], stages, items, dependencies, evidence, visualAssets, metrics, deliveryStatuses, visualCompliance });
    },
  );

  server.registerTool(
    "create_backlog_item",
    {
      description: "Create a feature, story, or task in a project's Backlog. Stories require at least one deterministic acceptance criterion.",
      inputSchema: {
        projectId: z.string().uuid(),
        title: z.string().min(1).max(240),
        description: z.string().max(5000).optional(),
        kind: z.enum(["feature", "story", "task"]).default("story"),
        priority: z.enum(["urgent", "high", "medium", "low"]).default("medium"),
        parentId: z.string().uuid().optional(),
        assignee: z.string().max(120).optional(),
        acceptanceCriteria: z.array(acceptanceCriterionSchema).min(1).max(30).optional(),
        invariants: z.array(z.string().min(1).max(1000)).max(30).optional(),
        visualEvidenceRequired: z.boolean().default(false).describe("Mark this feature or story as a visual change. Child stories inherit the marker from a visual feature."),
        interactionEvidenceRequired: z.boolean().default(false).describe("Require a human-reviewed, continuous real-time interaction walkthrough. Use for material click, drag, touch, keyboard, navigation, animation, or multi-step UI behavior."),
        designCardType: z.enum(["visual_concept", "screen_mockup"]).optional().describe("Use visual_concept for the alternatives/selection card or screen_mockup for a shared mockup card."),
        screenNames: z.array(z.string().min(1).max(240)).max(100).optional().describe("Every affected screen, important state, and viewport variant that needs an approved mockup."),
      },
    },
    async ({ projectId, title, description, kind, priority, parentId, assignee, acceptanceCriteria, invariants, visualEvidenceRequired, interactionEvidenceRequired, designCardType, screenNames }) => {
      const created = await rest("/rpc/create_backlog_item", {
          method: "POST",
          body: JSON.stringify({
            target_project_id: projectId,
            item_title: title,
            item_description: description ?? "",
            item_kind: kind,
            item_priority: priority,
            parent_work_item_id: parentId ?? null,
            item_assignee: assignee ?? null,
            item_acceptance_criteria: (acceptanceCriteria ?? []).map((criterion) => ({
              statement: criterion.statement,
              verification_method: criterion.verificationMethod,
              verification_ref: criterion.verificationRef,
              expected_result: criterion.expectedResult,
            })),
            item_invariants: invariants ?? [],
            actor_name: "AI agent",
          }),
        });
      const createdItem = Array.isArray(created) ? created[0] : null;
      if (kind === "story" && interactionEvidenceRequired && typeof createdItem?.id === "string") {
        await rest("/rpc/set_interaction_evidence_requirement", {
          method: "POST",
          body: JSON.stringify({ target_work_item_id: createdItem.id, required: true, actor_name: "AI agent" }),
        });
      }
      if (kind === "story" && typeof createdItem?.id === "string" && (designCardType || screenNames?.length)) {
        return textResult(await rest("/rpc/set_design_card", {
          method: "POST",
          body: JSON.stringify({
            target_work_item_id: createdItem.id,
            target_design_card_type: designCardType ?? null,
            target_screen_names: screenNames ?? [],
            actor_name: "AI agent",
          }),
        }));
      }
      if ((kind === "story" || kind === "feature") && visualEvidenceRequired && typeof createdItem?.id === "string") {
        const updated = await rest("/rpc/set_visual_evidence_requirement", {
          method: "POST",
          body: JSON.stringify({ target_work_item_id: createdItem.id, required: true, actor_name: "AI agent" }),
        });
        return textResult(updated);
      }
      return textResult(created);
    },
  );

  server.registerTool(
    "move_work_item",
    {
      description: "Move a card by one allowed step in the governed delivery path and record the activity. Skipping required stages is rejected by PostgreSQL.",
      inputSchema: {
        workItemId: z.string().uuid(),
        stage: z.enum(["backlog", "analyse", "plan", "build", "validate", "review", "merge", "post_merge", "done"]),
        actor: z.string().max(120).default("AI agent"),
        summary: z.string().max(500).optional(),
      },
    },
    async ({ workItemId, stage, actor, summary }) =>
      textResult(
        await rest("/rpc/move_work_item", {
          method: "POST",
          body: JSON.stringify({
            target_work_item_id: workItemId,
            target_stage_slug: stage,
            actor_name: actor,
            event_summary: summary ?? null,
          }),
        }),
      ),
  );

  server.registerTool(
    "update_work_item",
    {
      description: "Update the mutable planning fields on a card.",
      inputSchema: {
        workItemId: z.string().uuid(),
        title: z.string().min(1).max(240).optional(),
        description: z.string().max(5000).optional(),
        priority: z.enum(["urgent", "high", "medium", "low"]).optional(),
        parentId: z.string().uuid().nullable().optional(),
        assignee: z.string().max(120).nullable().optional(),
        executionState: z.enum(["queued", "running", "waiting_for_human", "blocked", "failed", "complete", "cancelled"]).nullable().optional(),
        blockedReason: z.string().max(1000).nullable().optional(),
        estimatePoints: z.number().int().min(1).max(100).optional(),
        visualEvidenceRequired: z.boolean().optional().describe("Mark or unmark a feature or story as a visual change while it is still in Backlog, Analyse, or Plan."),
        interactionEvidenceRequired: z.boolean().optional().describe("Require or remove a governed interaction walkthrough while the story is still in Backlog, Analyse, or Plan."),
        designCardType: z.enum(["visual_concept", "screen_mockup"]).nullable().optional(),
        screenNames: z.array(z.string().min(1).max(240)).max(100).optional(),
      },
    },
    async ({ workItemId, parentId, executionState, blockedReason, estimatePoints, visualEvidenceRequired, interactionEvidenceRequired, designCardType, screenNames, ...fields }) => {
      const body = {
        ...fields,
        ...(parentId !== undefined ? { parent_id: parentId } : {}),
        ...(executionState !== undefined ? { execution_state: executionState } : {}),
        ...(blockedReason !== undefined ? { blocked_reason: blockedReason } : {}),
        ...(estimatePoints !== undefined ? { estimate_points: estimatePoints } : {}),
      };
      const updated = await rest(`/work_items?id=eq.${workItemId}`, { method: "PATCH", body: JSON.stringify(body) });
      const updatedItem = Array.isArray(updated) ? updated[0] : null;
      if (updatedItem && typeof updatedItem.project_id === "string") {
        await rest("/activity_events", {
          method: "POST",
          body: JSON.stringify({
            project_id: updatedItem.project_id,
            work_item_id: workItemId,
            event_type: "work_item.updated",
            actor_type: "agent",
            actor_name: "AI agent",
            summary: `Updated ${String(updatedItem.item_key ?? "work item")}`,
            details: {},
          }),
        });
      }
      if (visualEvidenceRequired !== undefined) {
        await rest("/rpc/set_visual_evidence_requirement", {
          method: "POST",
          body: JSON.stringify({ target_work_item_id: workItemId, required: visualEvidenceRequired, actor_name: "AI agent" }),
        });
      }
      if (interactionEvidenceRequired !== undefined) {
        await rest("/rpc/set_interaction_evidence_requirement", {
          method: "POST",
          body: JSON.stringify({ target_work_item_id: workItemId, required: interactionEvidenceRequired, actor_name: "AI agent" }),
        });
      }
      if (designCardType !== undefined || screenNames !== undefined) {
        return textResult(await rest("/rpc/set_design_card", {
          method: "POST",
          body: JSON.stringify({
            target_work_item_id: workItemId,
            target_design_card_type: designCardType ?? null,
            target_screen_names: screenNames ?? [],
            actor_name: "AI agent",
          }),
        }));
      }
      return textResult(updated);
    },
  );

  server.registerTool(
    "complete_task",
    {
      description: "Mark one implemented child task complete. This atomically synchronizes progress, execution state, and completion time so the parent story can satisfy its task gate.",
      inputSchema: {
        taskId: z.string().uuid(),
        actor: z.string().max(120).default("AI agent"),
        summary: z.string().max(500).optional(),
      },
    },
    async ({ taskId, actor, summary }) => textResult(await rest("/rpc/complete_task", {
      method: "POST",
      body: JSON.stringify({
        target_task_id: taskId,
        actor_name: actor,
        completion_summary: summary ?? null,
      }),
    })),
  );

  server.registerTool(
    "set_work_item_prerequisites",
    {
      description: "Replace a story or feature's prerequisite links. Cycles, cross-project links, and mixed-type links are rejected.",
      inputSchema: {
        workItemId: z.string().uuid(),
        prerequisiteIds: z.array(z.string().uuid()).max(100).default([]),
      },
    },
    async ({ workItemId, prerequisiteIds }) => textResult(await rest("/rpc/set_work_item_dependencies", {
      method: "POST",
      body: JSON.stringify({ target_work_item_id: workItemId, prerequisite_ids: prerequisiteIds }),
    })),
  );

  server.registerTool(
    "set_acceptance_criteria",
    {
      description: "Define or replace a story's deterministic acceptance criteria before Build. Every criterion identifies how it is verified and the exact expected result.",
      inputSchema: {
        workItemId: z.string().uuid(),
        criteria: z.array(acceptanceCriterionSchema).min(1).max(30),
        actor: z.string().min(1).max(120).default("AI agent"),
      },
    },
    async ({ workItemId, criteria, actor }) => textResult(await rest("/rpc/set_work_item_acceptance_criteria", {
      method: "POST",
      body: JSON.stringify({
        target_work_item_id: workItemId,
        criteria: criteria.map((criterion) => ({
          statement: criterion.statement,
          verification_method: criterion.verificationMethod,
          verification_ref: criterion.verificationRef,
          expected_result: criterion.expectedResult,
        })),
        actor_name: actor,
      }),
    })),
  );

  server.registerTool(
    "set_work_item_invariants",
    {
      description: "Define the constraints a story must preserve. Invariants become immutable once Build begins.",
      inputSchema: {
        workItemId: z.string().uuid(),
        invariants: z.array(z.string().min(1).max(1000)).max(30),
        actor: z.string().min(1).max(120).default("AI agent"),
      },
    },
    async ({ workItemId, invariants, actor }) => textResult(await rest("/rpc/set_work_item_invariants", {
      method: "POST",
      body: JSON.stringify({ target_work_item_id: workItemId, target_invariants: invariants, actor_name: actor }),
    })),
  );

  server.registerTool(
    "list_ready_stories",
    {
      description: "List stories eligible for agent work: not complete, not already running, and with every prerequisite Done.",
      inputSchema: { projectId: z.string().uuid() },
    },
    async ({ projectId }) => textResult(await rest(`/agent_ready_stories?project_id=eq.${projectId}&order=priority.asc,created_at.asc`)),
  );

  server.registerTool(
    "list_project_quality_constraints",
    {
      description: "List the project's recommended, required, and explicitly waived quality constraints.",
      inputSchema: { projectId: z.string().uuid() },
    },
    async ({ projectId }) => textResult(await rest(`/project_quality_constraints?project_id=eq.${projectId}&order=constraint_key.asc`)),
  );

  server.registerTool(
    "set_project_quality_constraint",
    {
      description: "Make a recommended project quality check required and deterministic, or record an explicit user waiver with its rationale.",
      inputSchema: {
        projectId: z.string().uuid(),
        constraintKey: z.enum(["unit_testing", "regression_testing"]),
        policy: z.enum(["recommended", "required", "waived"]),
        actor: z.string().min(1).max(120),
        description: z.string().max(2000).optional(),
        verificationRef: z.string().max(2000).optional(),
        expectedResult: z.string().max(2000).optional(),
        waiverReason: z.string().max(2000).optional(),
      },
    },
    async ({ projectId, constraintKey, policy, actor, description, verificationRef, expectedResult, waiverReason }) => textResult(
      await rest("/rpc/set_project_quality_constraint", {
        method: "POST",
        body: JSON.stringify({
          target_project_id: projectId,
          target_constraint_key: constraintKey,
          target_policy: policy,
          actor_name: actor,
          target_description: description ?? null,
          target_verification_ref: verificationRef ?? null,
          target_expected_result: expectedResult ?? null,
          target_waiver_reason: waiverReason ?? null,
        }),
      }),
    ),
  );

  server.registerTool(
    "claim_next_ready_work_item",
    {
      description: "Atomically fetch and claim the highest-priority dependency-ready story. Returns only the focused story, required child tasks, invariants, deterministic story acceptance criteria, and the current stage's acceptance criteria for promotion. Call it again after every Done or Blocked outcome.",
      inputSchema: {
        projectId: z.string().uuid(),
        agentName: z.string().min(1).max(120),
      },
    },
    async ({ projectId, agentName }) => textResult(await attachRepositoryToContext(await rest("/rpc/claim_next_work_package", {
        method: "POST",
        body: JSON.stringify({ target_project_id: projectId, agent_name: agentName }),
      }), projectId)),
  );

  server.registerTool(
    "get_work_item_context",
    {
      description: "Get the focused story work package and the acceptance criteria required to promote it from its current stage.",
      inputSchema: { workItemId: z.string().uuid() },
    },
    async ({ workItemId }) => textResult(await attachRepositoryToContext(await rest("/rpc/get_governed_work_item_context", {
      method: "POST",
      body: JSON.stringify({ target_work_item_id: workItemId }),
    }))),
  );

  server.registerTool(
    "get_design_card_completion_requirements",
    {
      description: "Check whether a design-only visual concept or screen-mockup card may close from Plan. Returns the analysis, plan, task, asset, artefact, and human-approval requirements without claiming that software implementation occurred.",
      inputSchema: { workItemId: z.string().uuid() },
    },
    async ({ workItemId }) => textResult(await rest("/rpc/design_card_completion_requirements", {
      method: "POST",
      body: JSON.stringify({ target_work_item_id: workItemId }),
    })),
  );

  server.registerTool(
    "complete_design_card",
    {
      description: "Complete an approved design-only card directly from Plan to Done. Creates a durable design-contract revision and never creates implementation, test, review, merge, or regression evidence.",
      inputSchema: {
        workItemId: z.string().uuid(),
        actor: z.string().min(1).max(120),
      },
    },
    async ({ workItemId, actor }) => textResult(await rest("/rpc/complete_design_card", {
      method: "POST",
      body: JSON.stringify({ target_work_item_id: workItemId, actor_name: actor }),
    })),
  );

  server.registerTool(
    "get_mockup_implementation_package",
    {
      description: "Resolve the governed build package for Product Design image-to-code. Returns the repository, human-approved static mockups, declared screen/state/viewports, approved design artefacts, acceptance criteria, required measurement contract, and durable evidence destinations. The connected host performs the React/HTML implementation; Agent Boards remains the control plane.",
      inputSchema: {
        workItemId: z.string().uuid(),
        workflow: z.literal("product-design:image-to-code").default("product-design:image-to-code"),
      },
    },
    async ({ workItemId }) => textResult(await rest("/rpc/get_mockup_implementation_package", {
      method: "POST",
      body: JSON.stringify({ target_work_item_id: workItemId }),
    })),
  );

  server.registerTool(
    "get_visual_critique_package",
    {
      description: "Resolve the governed comparison package for Product Design design-qa. Binds a human-approved static mockup to an exact-revision rendered React/HTML screenshot at the same viewport and returns the required measurement and evidence contract.",
      inputSchema: {
        workItemId: z.string().uuid(),
        screenName: z.string().min(1).max(240),
        revision: z.string().min(1).max(240),
        workflow: z.literal("product-design:design-qa").default("product-design:design-qa"),
      },
    },
    async ({ workItemId, screenName, revision }) => textResult(await rest("/rpc/get_visual_critique_package", {
      method: "POST",
      body: JSON.stringify({
        target_work_item_id: workItemId,
        target_screen_name: screenName,
        target_revision: revision,
      }),
    })),
  );

  server.registerTool(
    "record_visual_critique",
    {
      description: "Record the durable Product Design design-qa result for one exact screen, revision, and viewport. Stores P0-P3 findings plus measured typography, geometry, spacing, control, and colour fidelity. The server derives tolerance failures; unresolved or out-of-tolerance P0/P1/P2 values can never pass the promotion gate.",
      inputSchema: {
        workItemId: z.string().uuid(),
        screenName: z.string().min(1).max(240),
        sourceMockupAssetId: z.string().uuid(),
        validationAssetId: z.string().uuid(),
        revision: z.string().min(1).max(240),
        viewportWidth: z.number().int().positive(),
        viewportHeight: z.number().int().positive(),
        comparisonMethod: z.enum(["side_by_side", "overlay", "pixel_diff", "html_reference"]),
        sameViewport: z.boolean(),
        structuralMatch: z.boolean(),
        controlsPresent: z.boolean(),
        measurements: z.array(visualMeasurementSchema).min(1).max(2000),
        findings: z.array(visualCritiqueFindingSchema).max(500).default([]),
        measurementMethod: z.string().min(1).max(2000),
        notes: z.string().max(4000).default(""),
        actor: z.string().min(1).max(120).default("AI agent"),
        workflow: z.literal("product-design:design-qa").default("product-design:design-qa"),
      },
    },
    async ({
      workItemId, screenName, sourceMockupAssetId, validationAssetId,
      revision, viewportWidth, viewportHeight, comparisonMethod,
      sameViewport, structuralMatch, controlsPresent, measurements,
      findings, measurementMethod, notes, actor,
    }) => textResult(await rest("/rpc/record_visual_critique", {
      method: "POST",
      body: JSON.stringify({
        target_work_item_id: workItemId,
        target_screen_name: screenName,
        target_source_mockup_asset_id: sourceMockupAssetId,
        target_validation_asset_id: validationAssetId,
        target_revision: revision,
        target_viewport_width: viewportWidth,
        target_viewport_height: viewportHeight,
        target_comparison_method: comparisonMethod,
        target_same_viewport: sameViewport,
        target_structural_match: structuralMatch,
        target_controls_present: controlsPresent,
        target_measurements: measurements,
        target_findings: findings,
        target_measurement_method: measurementMethod,
        critique_notes: notes,
        actor_name: actor,
      }),
    })),
  );

  server.registerTool(
    "claim_work_item",
    {
      description: "Atomically claim a ready story for an agent. The database rejects stories with any incomplete prerequisite.",
      inputSchema: {
        workItemId: z.string().uuid(),
        agentName: z.string().min(1).max(120),
      },
    },
    async ({ workItemId, agentName }) => textResult(await rest("/rpc/claim_work_item", {
      method: "POST",
      body: JSON.stringify({ target_work_item_id: workItemId, agent_name: agentName }),
    })),
  );

  server.registerTool(
    "block_work_item",
    {
      description: "Mark an in-progress work item Blocked with a concrete reason and remove it from the autonomous ready queue. The agent should then claim the next ready item.",
      inputSchema: {
        workItemId: z.string().uuid(),
        agentName: z.string().min(1).max(120),
        reason: z.string().min(1).max(1000),
      },
    },
    async ({ workItemId, agentName, reason }) => textResult(await rest("/rpc/block_work_item", {
      method: "POST",
      body: JSON.stringify({ target_work_item_id: workItemId, agent_name: agentName, reason }),
    })),
  );

  server.registerTool(
    "release_work_item",
    {
      description: "Return running work to the ready queue when an agent must stop without blocking it. Do not use this for a real dependency or human decision; use block_work_item instead.",
      inputSchema: {
        workItemId: z.string().uuid(),
        agentName: z.string().min(1).max(120),
        reason: z.string().max(1000).optional(),
      },
    },
    async ({ workItemId, agentName, reason }) => textResult(await rest("/rpc/release_work_item", {
      method: "POST",
      body: JSON.stringify({ target_work_item_id: workItemId, agent_name: agentName, reason: reason ?? null }),
    })),
  );

  server.registerTool(
    "list_work_item_evidence",
    {
      description: "List durable analysis, plan, implementation, test, review, merge, and post-merge regression evidence recorded for a work item.",
      inputSchema: { workItemId: z.string().uuid() },
    },
    async ({ workItemId }) => textResult(await rest(
      `/work_item_evidence?work_item_id=eq.${workItemId}&order=created_at.asc`,
    )),
  );

  server.registerTool(
    "list_work_item_assets",
    {
      description: "List the visual references, mockups, screenshots, visual validation, and validation recordings attached to a work item.",
      inputSchema: { workItemId: z.string().uuid() },
    },
    async ({ workItemId }) => textResult(await rest(
      `/work_item_assets?work_item_id=eq.${workItemId}&order=is_primary.desc,created_at.desc`,
    )),
  );

  server.registerTool(
    "list_visual_design_validations",
    {
      description: "List structured screen-level fidelity comparisons for a visual story, including source mockup, exact revision, viewport, structural result, and unresolved P0/P1/P2 findings.",
      inputSchema: { workItemId: z.string().uuid() },
    },
    async ({ workItemId }) => textResult(await rest(
      `/work_item_visual_validations?work_item_id=eq.${workItemId}&order=created_at.asc`,
    )),
  );

  server.registerTool(
    "get_visual_story_compliance",
    {
      description: "Audit a visual story against the current measured-fidelity contract, including every declared screen, the exact accepted revision, material failures, and any governed legacy remediation.",
      inputSchema: { workItemId: z.string().uuid() },
    },
    async ({ workItemId }) => textResult(await rest("/rpc/get_visual_story_compliance", {
      method: "POST",
      body: JSON.stringify({ target_work_item_id: workItemId }),
    })),
  );

  server.registerTool(
    "list_visual_compliance_failures",
    {
      description: "List active visual stories whose current-contract measured fidelity is incomplete or failing. A Done card remains in this result until direct or linked remediation evidence passes.",
      inputSchema: { projectId: z.string().uuid() },
    },
    async ({ projectId }) => textResult(await rest(
      `/visual_story_compliance?project_id=eq.${projectId}&compliant=eq.false&order=completed_at.desc.nullslast,item_key.asc`,
    )),
  );

  server.registerTool(
    "ensure_visual_compliance_remediation",
    {
      description: "Idempotently create or return the governed urgent remediation story for a legacy Done visual story that fails the current measured-fidelity contract. Historical delivery evidence is preserved.",
      inputSchema: {
        workItemId: z.string().uuid(),
        actor: z.string().min(1).max(120).default("AI agent"),
      },
    },
    async ({ workItemId, actor }) => textResult(await rest("/rpc/ensure_visual_compliance_remediation", {
      method: "POST",
      body: JSON.stringify({ target_work_item_id: workItemId, actor_name: actor }),
    })),
  );

  server.registerTool(
    "record_visual_design_validation",
    {
      description: "Record measured fidelity between one rendered screen and its human-approved mockup at the same viewport. Required typography, geometry, spacing, control and colour measurements are stored; tolerance failures and P0/P1/P2 counts are derived by the server and power the Validate-to-Review gate.",
      inputSchema: {
        workItemId: z.string().uuid(),
        screenName: z.string().min(1).max(240),
        sourceMockupAssetId: z.string().uuid(),
        validationAssetId: z.string().uuid(),
        revision: z.string().min(1).max(240),
        viewportWidth: z.number().int().positive(),
        viewportHeight: z.number().int().positive(),
        comparisonMethod: z.enum(["side_by_side", "overlay", "pixel_diff", "html_reference"]),
        sameViewport: z.boolean(),
        representsApprovedDesign: z.boolean(),
        structuralMatch: z.boolean(),
        controlsPresent: z.boolean(),
        measurements: z.array(visualMeasurementSchema).min(1).max(2000),
        measurementMethod: z.string().min(1).max(2000),
        notes: z.string().max(4000).default(""),
        actor: z.string().min(1).max(120).default("AI agent"),
      },
    },
    async ({
      workItemId, screenName, sourceMockupAssetId, validationAssetId,
      revision, viewportWidth, viewportHeight, comparisonMethod,
      sameViewport, representsApprovedDesign, structuralMatch,
      controlsPresent, measurements, measurementMethod, notes, actor,
    }) => textResult(await rest("/rpc/record_visual_design_validation", {
      method: "POST",
      body: JSON.stringify({
        target_work_item_id: workItemId,
        target_screen_name: screenName,
        target_source_mockup_asset_id: sourceMockupAssetId,
        target_validation_asset_id: validationAssetId,
        target_revision: revision,
        target_viewport_width: viewportWidth,
        target_viewport_height: viewportHeight,
        target_comparison_method: comparisonMethod,
        target_same_viewport: sameViewport,
        target_represents_approved_design: representsApprovedDesign,
        target_structural_match: structuralMatch,
        target_controls_present: controlsPresent,
        target_measurements: measurements,
        target_measurement_method: measurementMethod,
        validation_notes: notes,
        actor_name: actor,
      }),
    })),
  );

  server.registerTool(
    "set_application_design_scope",
    {
      description: "Make a story a visual concept or screen-mockup design card, or declare the exact screens, important states, and viewport variants required by a visual implementation story.",
      inputSchema: {
        workItemId: z.string().uuid(),
        designCardType: z.enum(["visual_concept", "screen_mockup"]).nullable().default(null),
        screenNames: z.array(z.string().min(1).max(240)).max(100).default([]),
        actor: z.string().min(1).max(120).default("AI agent"),
      },
    },
    async ({ workItemId, designCardType, screenNames, actor }) => textResult(await rest("/rpc/set_design_card", {
      method: "POST",
      body: JSON.stringify({
        target_work_item_id: workItemId,
        target_design_card_type: designCardType,
        target_screen_names: screenNames,
        actor_name: actor,
      }),
    })),
  );

  server.registerTool(
    "get_project_design_governance",
    {
      description: "Read the selected visual concept, approved design-concept artefact, approved design system, and approval audit for a project.",
      inputSchema: { projectId: z.string().uuid() },
    },
    async ({ projectId }) => textResult(await rest(`/project_design_governance?project_id=eq.${projectId}&limit=1`)),
  );

  server.registerTool(
    "approve_visual_concept",
    {
      description: "Record a person's explicit selection from a visual concept card. Do not call this from autonomous agent judgment; it represents human design authority and requires at least two attached options.",
      inputSchema: {
        workItemId: z.string().uuid(),
        assetId: z.string().uuid(),
        humanName: z.string().min(1).max(120),
      },
    },
    async ({ workItemId, assetId, humanName }) => textResult(await rest("/rpc/approve_visual_concept", {
      method: "POST",
      body: JSON.stringify({ target_work_item_id: workItemId, target_asset_id: assetId, actor_name: humanName }),
    })),
  );

  server.registerTool(
    "approve_design_artefact",
    {
      description: "Record a person's approval of the design-concept or design-system artefact after it contains every required section. Do not self-approve as an autonomous agent.",
      inputSchema: {
        projectId: z.string().uuid(),
        artefact: z.enum(["design_concept", "design_system"]),
        humanName: z.string().min(1).max(120),
      },
    },
    async ({ projectId, artefact, humanName }) => textResult(await rest(
      artefact === "design_concept" ? "/rpc/approve_design_concept" : "/rpc/approve_style_guide",
      { method: "POST", body: JSON.stringify({ target_project_id: projectId, actor_name: humanName }) },
    )),
  );

  server.registerTool(
    "approve_screen_mockup",
    {
      description: "Record a person's approval of a mockup assigned to a declared screen/state/viewport. Do not self-approve as an autonomous agent.",
      inputSchema: {
        assetId: z.string().uuid(),
        humanName: z.string().min(1).max(120),
      },
    },
    async ({ assetId, humanName }) => textResult(await rest("/rpc/approve_screen_mockup", {
      method: "POST",
      body: JSON.stringify({ target_asset_id: assetId, actor_name: humanName }),
    })),
  );

  server.registerTool(
    "attach_work_item_asset",
    {
      description: "Attach visual proof media to a story. Revision-bearing implementation, validation images, and validation recordings must identify the exact source revision.",
      inputSchema: {
        workItemId: z.string().uuid(),
        assetType: visualAssetTypeSchema,
        sourceUrl: mediaSourceSchema,
        actor: z.string().min(1).max(120),
        caption: z.string().max(2000).default(""),
        thumbnailUrl: imageSourceSchema.optional(),
        mimeType: z.string().regex(/^(image|video)\//).max(120).default("image/png"),
        filename: z.string().max(500).optional(),
        viewportWidth: z.number().int().positive().optional(),
        viewportHeight: z.number().int().positive().optional(),
        revision: z.string().min(1).max(240).optional(),
        evidenceId: z.string().uuid().optional(),
        makePrimary: z.boolean().default(false),
        screenName: z.string().min(1).max(240).optional().describe("Required for a screen mockup; must match a screen/state/viewport declared on the owning story or design card."),
      },
    },
    async ({ workItemId, assetType, sourceUrl, actor, caption, thumbnailUrl, mimeType, filename, viewportWidth, viewportHeight, revision, evidenceId, makePrimary, screenName }) => {
      const created = await rest("/rpc/attach_work_item_asset", {
        method: "POST",
        body: JSON.stringify({
          target_work_item_id: workItemId,
          target_asset_type: assetType,
          asset_source_url: sourceUrl,
          actor_name: actor,
          asset_caption: caption,
          asset_thumbnail_url: thumbnailUrl ?? null,
          asset_mime_type: mimeType,
          asset_filename: filename ?? null,
          asset_viewport_width: viewportWidth ?? null,
          asset_viewport_height: viewportHeight ?? null,
          target_revision: revision ?? null,
          target_evidence_id: evidenceId ?? null,
          make_primary: makePrimary,
        }),
      });
      const createdAsset = Array.isArray(created) ? created[0] : null;
      if (screenName && typeof createdAsset?.id === "string") {
        return textResult(await rest("/rpc/set_work_item_asset_screen", {
          method: "POST",
          body: JSON.stringify({ target_asset_id: createdAsset.id, target_screen_name: screenName, actor_name: actor }),
        }));
      }
      return textResult(created);
    },
  );

  server.registerTool(
    "attach_validation_recording",
    {
      description: "Upload a human-readable UI interaction walkthrough into Agent Boards-managed storage. The server verifies actual media duration. Capture continuously at real-time speed with a visible pointer/touch indicator and deliberate timestamped actions; rapid montages, jump cuts, accelerated playback, or unobservable interactions are invalid. A person must review the recording before it can satisfy the gate.",
      inputSchema: {
        workItemId: z.string().uuid(),
        contentBase64: z.string().min(1).max(70_000_000).regex(/^[A-Za-z0-9+/=]+$/),
        actor: z.string().min(1).max(120),
        revision: z.string().min(1).max(240),
        caption: z.string().min(1).max(2000),
        mimeType: mediaMimeTypeSchema.default("video/webm"),
        filename: z.string().max(500).optional(),
        viewportWidth: z.number().int().positive().optional(),
        viewportHeight: z.number().int().positive().optional(),
        evidenceId: z.string().uuid(),
        continuousCapture: z.literal(true),
        pointerVisible: z.literal(true),
        playbackSpeed: z.literal(1),
        walkthroughSteps: z.array(z.object({
          atSeconds: z.number().nonnegative(),
          action: z.string().min(1).max(500),
          expectedResult: z.string().min(1).max(1000),
        })).min(2).max(50),
      },
    },
    async ({ workItemId, contentBase64, actor, revision, caption, mimeType, filename, viewportWidth, viewportHeight, evidenceId, continuousCapture, pointerVisible, playbackSpeed, walkthroughSteps }) => {
      const uploaded = await storeMedia(Buffer.from(contentBase64, "base64"), mimeType, filename ?? "");
      try {
        const durationSeconds = await probeVideoDuration(uploaded.url);
        const assets = await rest("/rpc/attach_validation_recording", {
          method: "POST",
          body: JSON.stringify({
            target_work_item_id: workItemId,
            asset_source_url: uploaded.url,
            actor_name: actor,
            recording_caption: caption,
            recording_mime_type: mimeType,
            recording_filename: uploaded.filename,
            recording_viewport_width: viewportWidth ?? null,
            recording_viewport_height: viewportHeight ?? null,
            target_revision: revision,
            target_evidence_id: evidenceId,
            walkthrough_manifest: {
              duration_seconds: durationSeconds,
              continuous_capture: continuousCapture,
              pointer_visible: pointerVisible,
              playback_speed: playbackSpeed,
              steps: walkthroughSteps.map((step) => ({ at_seconds: step.atSeconds, action: step.action, expected_result: step.expectedResult })),
            },
          }),
        });
        return textResult({ upload: { ...uploaded, durationSeconds }, assets });
      } catch (error) {
        await deleteStoredMedia(uploaded.url);
        throw error;
      }
    },
  );

  server.registerTool(
    "set_primary_work_item_asset",
    {
      description: "Choose the visual shown on the board card for a work item.",
      inputSchema: { assetId: z.string().uuid(), actor: z.string().min(1).max(120).default("AI agent") },
    },
    async ({ assetId, actor }) => textResult(await rest("/rpc/set_primary_work_item_asset", {
      method: "POST", body: JSON.stringify({ target_asset_id: assetId, actor_name: actor }),
    })),
  );

  server.registerTool(
    "delete_work_item_asset",
    {
      description: "Remove an incorrect visual asset while retaining an audit event that it was removed.",
      inputSchema: { assetId: z.string().uuid(), actor: z.string().min(1).max(120).default("AI agent") },
    },
    async ({ assetId, actor }) => textResult(await rest("/rpc/delete_work_item_asset", {
      method: "POST", body: JSON.stringify({ target_asset_id: assetId, actor_name: actor }),
    })),
  );

  server.registerTool(
    "list_work_item_activity",
    {
      description: "List the complete audit history for a work item, including claims, governed stage transitions, evidence records, comments, and blocks.",
      inputSchema: { workItemId: z.string().uuid() },
    },
    async ({ workItemId }) => textResult(await rest(
      `/activity_events?work_item_id=eq.${workItemId}&order=created_at.asc`,
    )),
  );

  server.registerTool(
    "list_work_item_comments",
    {
      description: "List human and agent comments attached to a work item in chronological order.",
      inputSchema: { workItemId: z.string().uuid() },
    },
    async ({ workItemId }) => textResult(await rest(
      `/work_item_comments?work_item_id=eq.${workItemId}&order=created_at.asc`,
    )),
  );

  server.registerTool(
    "add_work_item_comment",
    {
      description: "Add a durable progress update, decision, or clarification question to a work item. This supplements delivery evidence; it does not satisfy a promotion gate.",
      inputSchema: {
        workItemId: z.string().uuid(),
        body: z.string().min(1).max(10000),
        actor: z.string().min(1).max(120),
        actorType: z.enum(["human", "agent"]).default("agent"),
      },
    },
    async ({ workItemId, body, actor, actorType }) => textResult(await rest("/rpc/add_work_item_comment", {
      method: "POST",
      body: JSON.stringify({
        target_work_item_id: workItemId,
        comment_body: body,
        actor_name: actor,
        target_actor_type: actorType,
      }),
    })),
  );

  server.registerTool(
    "record_work_item_evidence",
    {
      description: "Record a delivery gate result. Revision-bearing evidence must identify the exact revision. Approved review evidence requires details.unresolved_findings = 0. Merge evidence records the merged revision and details.reviewed_revision. Post-merge verification always requires passing regression evidence for the merged revision; when the regression suite is explicitly waived, record the passing alternative in details.alternative_check. Other project quality evidence becomes a Done gate when its constraint is required.",
      inputSchema: {
        workItemId: z.string().uuid(),
        evidenceType: z.enum(["analysis", "plan", "implementation", "test", "unit_test", "review", "merge", "regression"]),
        outcome: z.enum(["recorded", "passed", "failed", "approved", "rejected", "merged"]),
        summary: z.string().min(1).max(2000),
        actor: z.string().min(1).max(120),
        revision: z.string().min(1).max(240).optional(),
        url: z.string().url().max(2000).optional(),
        details: z.record(z.string(), z.unknown()).default({}),
      },
    },
    async ({ workItemId, evidenceType, outcome, summary, actor, revision, url, details }) => textResult(
      await rest("/rpc/record_work_item_evidence", {
        method: "POST",
        body: JSON.stringify({
          target_work_item_id: workItemId,
          target_evidence_type: evidenceType,
          target_outcome: outcome,
          evidence_summary: summary,
          actor_name: actor,
          target_revision: revision ?? null,
          evidence_url: url ?? null,
          evidence_details: details,
        }),
      }),
    ),
  );

  server.registerTool(
    "record_acceptance_result",
    {
      description: "Record a deterministic acceptance criterion as passed or failed for an exact revision. Every criterion must pass for the same revision before Review.",
      inputSchema: {
        workItemId: z.string().uuid(),
        criterionId: z.string().uuid(),
        passed: z.boolean(),
        revision: z.string().min(1).max(240),
        summary: z.string().min(1).max(2000),
        actor: z.string().min(1).max(120),
        url: z.string().url().max(2000).optional(),
        details: z.record(z.string(), z.unknown()).default({}),
      },
    },
    async ({ workItemId, criterionId, passed, revision, summary, actor, url, details }) => textResult(
      await rest("/rpc/record_acceptance_result", {
        method: "POST",
        body: JSON.stringify({
          target_work_item_id: workItemId,
          criterion_id: criterionId,
          passed,
          target_revision: revision,
          result_summary: summary,
          actor_name: actor,
          evidence_url: url ?? null,
          evidence_details: details,
        }),
      }),
    ),
  );

  server.registerTool(
    "list_project_records",
    {
      description: "List a project's durable artefacts and registers, including the brief, PRD, architecture, risks, and issues.",
      inputSchema: {
        projectId: z.string().uuid(),
        type: z.string().max(80).optional(),
      },
    },
    async ({ projectId, type }) => textResult(await rest(
      `/project_artifacts?project_id=eq.${projectId}${type ? `&artifact_type=eq.${encodeURIComponent(type)}` : ""}&order=updated_at.desc`,
    )),
  );

  server.registerTool(
    "get_project_record",
    {
      description: "Read one durable project artefact or register by its stable key.",
      inputSchema: {
        projectId: z.string().uuid(),
        key: z.string().min(1).max(120),
      },
    },
    async ({ projectId, key }) => textResult(await rest(
      `/project_artifacts?project_id=eq.${projectId}&artifact_key=eq.${encodeURIComponent(key)}&limit=1`,
    )),
  );

  server.registerTool(
    "upsert_project_record",
    {
      description: "Create or version a durable project artefact or register. Updating an existing key increments its version and records activity.",
      inputSchema: {
        projectId: z.string().uuid(),
        key: z.string().min(1).max(120).regex(/^[a-z0-9]+(?:-[a-z0-9]+)*$/),
        type: z.enum(["brief", "prd", "architecture", "design_concept", "design_system", "risk_register", "issue_register", "design", "workflow", "api", "evidence"]),
        title: z.string().min(1).max(240),
        description: z.string().max(2000).default(""),
        content: z.string().max(200000).default(""),
        status: z.enum(["draft", "current", "superseded"]).default("current"),
        actor: z.string().min(1).max(120).default("AI agent"),
        metadata: z.record(z.string(), z.unknown()).default({}),
      },
    },
    async ({ projectId, key, type, title, description, content, status, actor, metadata }) => textResult(
      await rest("/rpc/upsert_project_artifact", {
        method: "POST",
        body: JSON.stringify({
          target_project_id: projectId,
          target_artifact_key: key,
          target_artifact_type: type,
          artifact_title: title,
          artifact_description: description,
          artifact_content: content,
          artifact_status: status,
          actor_name: actor,
          artifact_metadata: metadata,
        }),
      }),
    ),
  );

  server.registerTool(
    "record_telemetry",
    {
      description: "Record an agent run's duration, token use, cost, and outcome against a project or card.",
      inputSchema: {
        projectId: z.string().uuid(),
        workItemId: z.string().uuid().optional(),
        agentName: z.string().min(1).max(120),
        provider: z.string().max(80).optional(),
        model: z.string().max(120).optional(),
        status: z.enum(["running", "completed", "failed", "cancelled"]),
        durationMs: z.number().int().min(0).default(0),
        inputTokens: z.number().int().min(0).default(0),
        outputTokens: z.number().int().min(0).default(0),
        estimatedCostUsd: z.number().min(0).default(0),
      },
    },
    async ({ projectId, workItemId, agentName, durationMs, inputTokens, outputTokens, estimatedCostUsd, ...fields }) =>
      textResult(
        await rest("/telemetry_events", {
          method: "POST",
          body: JSON.stringify({
            project_id: projectId,
            work_item_id: workItemId ?? null,
            agent_name: agentName,
            duration_ms: durationMs,
            input_tokens: inputTokens,
            output_tokens: outputTokens,
            estimated_cost_usd: estimatedCostUsd,
            ...fields,
          }),
        }),
      ),
  );

  return server;
}

app.post("/uploads", express.raw({ type: () => true, limit: "50mb" }), async (request, response) => {
  try {
    if (!Buffer.isBuffer(request.body)) {
      response.status(400).json({ error: "Upload the media file as the request body." });
      return;
    }
    const mimeType = String(request.headers["content-type"] ?? "").split(";")[0].trim();
    const encodedFilename = String(request.headers["x-file-name"] ?? "");
    const originalFilename = encodedFilename ? decodeURIComponent(encodedFilename) : "";
    const uploaded = await storeMedia(request.body, mimeType, originalFilename);
    const durationSeconds = mimeType.startsWith("video/") ? await probeVideoDuration(uploaded.url) : null;
    response.status(201).json({ ...uploaded, durationSeconds });
  } catch (error) {
    response.status(400).json({ error: error instanceof Error ? error.message : String(error) });
  }
});

app.get("/uploads/:filename", (request, response) => {
  const filename = request.params.filename;
  if (!/^[0-9a-f-]+\.(webm|mp4|mov|png|jpg|webp)$/i.test(filename)) {
    response.status(404).end();
    return;
  }
  response.setHeader("Cache-Control", "private, max-age=31536000, immutable");
  response.setHeader("Content-Disposition", "inline");
  response.sendFile(filename, { root: uploadDirectory, acceptRanges: true }, (error) => {
    if (error && !response.headersSent) response.status(404).end();
  });
});

app.delete("/uploads/:filename", async (request, response) => {
  const url = `/uploads/${request.params.filename}`;
  if (!/^[0-9a-f-]+\.(webm|mp4|mov|png|jpg|webp)$/i.test(request.params.filename)) {
    response.status(404).end();
    return;
  }
  await deleteStoredMedia(url);
  response.status(204).end();
});

app.get("/health", async (_request, response) => {
  try {
    await rest("/projects?select=id&limit=1");
    response.json({ ok: true, protocol: "mcp-streamable-http", upstream: "ok" });
  } catch (error) {
    response.status(503).json({ ok: false, upstream: "error", error: error instanceof Error ? error.message : String(error) });
  }
});

app.post("/mcp", async (request, response) => {
  const server = buildServer();
  const transport = new StreamableHTTPServerTransport({ sessionIdGenerator: undefined, enableJsonResponse: true });
  response.on("close", () => {
    void transport.close();
    void server.close();
  });
  try {
    await server.connect(transport);
    await transport.handleRequest(request, response, request.body);
  } catch (error) {
    if (!response.headersSent) response.status(500).json({ error: error instanceof Error ? error.message : String(error) });
  }
});

app.get("/mcp", (request, response) => {
  const projectId = typeof request.query.projectId === "string" ? request.query.projectId : "";
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(projectId)) {
    response.status(405).json({ error: "GET requires a valid projectId to open the board event stream." });
    return;
  }

  response.status(200);
  response.setHeader("Content-Type", "text/event-stream");
  response.setHeader("Cache-Control", "no-cache, no-transform");
  response.setHeader("Connection", "keep-alive");
  response.setHeader("X-Accel-Buffering", "no");
  response.flushHeaders();

  let closed = false;
  let polling = false;
  let cursor = new Date().toISOString();
  let cursorIds = new Set<string>();
  response.write(`event: connected\ndata: ${JSON.stringify({ projectId })}\n\n`);

  const poll = async () => {
    if (closed || polling) return;
    polling = true;
    try {
      const rows = await rest(`/activity_events?project_id=eq.${projectId}&created_at=gte.${encodeURIComponent(cursor)}&order=created_at.asc,id.asc&limit=100`) as Record<string, unknown>[];
      for (const row of rows) {
        const id = typeof row.id === "string" ? row.id : "";
        const createdAt = typeof row.created_at === "string" ? row.created_at : cursor;
        if (createdAt === cursor && cursorIds.has(id)) continue;
        if (createdAt > cursor) {
          cursor = createdAt;
          cursorIds = new Set();
        }
        cursorIds.add(id);
        response.write(`id: ${id}\nevent: board.change\ndata: ${JSON.stringify(row)}\n\n`);
      }
    } catch (error) {
      response.write(`event: board.error\ndata: ${JSON.stringify({ message: error instanceof Error ? error.message : String(error) })}\n\n`);
    } finally {
      polling = false;
    }
  };

  const pollTimer = setInterval(() => void poll(), 400);
  const heartbeatTimer = setInterval(() => response.write(": keepalive\n\n"), 15000);
  request.on("close", () => {
    closed = true;
    clearInterval(pollTimer);
    clearInterval(heartbeatTimer);
  });
});
app.delete("/mcp", (_request, response) => response.status(405).json({ error: "This stateless MCP endpoint has no sessions." }));

app.listen(port, "0.0.0.0", () => console.log(`Agent Boards MCP listening on ${port}`));
