import { BOARD_ASSET_COLUMNS, type BoardAsset, type BoardDesignGovernance, type AcceptanceCriterionInput, type ActivityEvent, type AgentMetrics, type AgentWorker, type Board, type BoardData, type DesignCardType, type Priority, type ProjectArtifact, type ProjectRepository, type ProjectSummary, type Stage, type TelemetryEvent, type WorkItem, type WorkItemAsset, type WorkItemAssetType, type WorkItemClaimStatus, type WorkItemComment, type WorkItemContext, type WorkItemDependency, type WorkItemEvidence, type WorkItemRegisterEntry, type WorkKind, type WorkerCapability } from "./types";

const BASE = "/api";

export interface UploadedMedia {
  id: string;
  url: string;
  mimeType: string;
  filename: string;
  size: number;
  durationSeconds: number | null;
}

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  for (let attempt = 0; attempt < 2; attempt += 1) {
    const response = await fetch(`${BASE}${path}`, {
      ...init,
      headers: { "Content-Type": "application/json", Prefer: "return=representation", ...init?.headers },
    });
    if (response.status === 503 && attempt === 0) {
      await new Promise((resolve) => window.setTimeout(resolve, 180));
      continue;
    }
    if (!response.ok) {
      const message = await response.text();
      throw new Error(message || `${response.status} ${response.statusText}`);
    }
    if (response.status === 204) return undefined as T;
    return response.json() as Promise<T>;
  }
  throw new Error("The service is temporarily unavailable.");
}

const boardAssetSelect = [...BOARD_ASSET_COLUMNS, "card_image_url"].join(",");

export const api = {
  uploadMedia: async (file: File) => {
    const response = await fetch("/uploads", {
      method: "POST",
      headers: {
        "Content-Type": file.type || "application/octet-stream",
        "X-File-Name": encodeURIComponent(file.name),
      },
      body: file,
    });
    if (!response.ok) throw new Error(await response.text() || `Upload failed: ${response.status}`);
    return response.json() as Promise<UploadedMedia>;
  },
  deleteUploadedMedia: async (url: string) => {
    const response = await fetch(url, { method: "DELETE" });
    if (!response.ok && response.status !== 404) throw new Error(await response.text() || `Could not remove upload: ${response.status}`);
  },
  projects: (scope: "active" | "archived" | "all" = "active") => request<ProjectSummary[]>(
    `/project_summary?${scope === "active" ? "status=neq.archived&" : scope === "archived" ? "status=eq.archived&" : ""}order=updated_at.desc`,
  ),
  project: async (projectId: string) => {
    const projects = await request<ProjectSummary[]>(`/project_summary?project_id=eq.${projectId}&limit=1`);
    return projects[0] ?? null;
  },
  createProject: async (value: { name: string; key: string; description: string; owner: string; repositoryUrl?: string; defaultBranch?: string }) => {
    const projects = await request<ProjectSummary[]>(value.repositoryUrl ? "/rpc/create_project_with_repository" : "/rpc/create_project", {
      method: "POST",
      body: JSON.stringify({
        project_name: value.name,
        project_key: value.key.toUpperCase(),
        project_description: value.description,
        project_owner: value.owner,
        ...(value.repositoryUrl ? {
          repository_url: value.repositoryUrl,
          repository_default_branch: value.defaultBranch || "main",
          actor_name: "You",
        } : {}),
      }),
    });
    return projects;
  },
  archiveProject: (projectId: string) => request<ProjectSummary[]>("/rpc/archive_project", {
    method: "POST",
    body: JSON.stringify({ target_project_id: projectId, actor_name: "You" }),
  }),
  restoreProject: (projectId: string) => request<ProjectSummary[]>("/rpc/restore_project", {
    method: "POST",
    body: JSON.stringify({ target_project_id: projectId, actor_name: "You" }),
  }),
  projectRepository: async (projectId: string) => {
    const repositories = await request<ProjectRepository[]>(`/project_repositories?project_id=eq.${projectId}&limit=1`);
    return repositories[0] ?? null;
  },
  setProjectRepository: (projectId: string, repositoryUrl: string, defaultBranch: string) =>
    request<ProjectRepository[]>("/rpc/set_project_repository", {
      method: "POST",
      body: JSON.stringify({
        target_project_id: projectId,
        target_repository_url: repositoryUrl,
        target_default_branch: defaultBranch,
        actor_name: "You",
      }),
    }),
  removeProjectRepository: (projectId: string) => request<void>("/rpc/remove_project_repository", {
    method: "POST",
    body: JSON.stringify({ target_project_id: projectId, actor_name: "You" }),
  }),
  boardCore: async (projectId: string): Promise<BoardData> => {
    const boards = await request<Board[]>(`/boards?project_id=eq.${projectId}`);
    if (!boards[0]) throw new Error("This project has no board.");
    const [stages, items] = await Promise.all([
      request<Stage[]>(`/board_stages?board_id=eq.${boards[0].id}&order=position.asc`),
      request<WorkItem[]>(`/work_items?board_id=eq.${boards[0].id}&archived_at=is.null&order=position.asc,created_at.asc`),
    ]);
    return { board: boards[0], stages, items, dependencies: [], assets: [] };
  },
  boardSettings: async (projectId: string) => {
    const boards = await request<Board[]>(`/boards?project_id=eq.${projectId}`);
    if (!boards[0]) throw new Error("This project has no board.");
    const stages = await request<Stage[]>(`/board_stages?board_id=eq.${boards[0].id}&order=position.asc`);
    return { board: boards[0], stages };
  },
  updateBoardStageSettings: async (stageId: string, value: { bucketTitle: string; purpose: string; responsibleActor: string; wipLimit: number | null; exitCriteria: string[] }) => {
    const stages = await request<Stage[]>("/rpc/update_board_stage_settings", {
      method: "POST",
      body: JSON.stringify({
        target_stage_id: stageId,
        stage_bucket_title: value.bucketTitle,
        stage_purpose: value.purpose,
        stage_responsible_actor: value.responsibleActor,
        stage_wip_limit: value.wipLimit,
        stage_exit_criteria: value.exitCriteria,
        actor_name: "You",
      }),
    });
    return stages[0] ?? null;
  },
  boardDependencies: (items: WorkItem[]) => items.length
    ? request<WorkItemDependency[]>(`/work_item_dependencies?work_item_id=in.(${items.map((item) => item.id).join(",")})&order=created_at.asc`)
    : Promise.resolve([]),
  boardAssets: (projectId: string) => request<BoardAsset[]>(`/work_item_assets?project_id=eq.${projectId}&select=${boardAssetSelect}&order=is_primary.desc,created_at.desc`),
  boardItemAssets: (workItemId: string) => request<BoardAsset[]>(`/work_item_assets?work_item_id=eq.${workItemId}&select=${boardAssetSelect}&order=is_primary.desc,created_at.desc`),
  boardDesignGovernance: async (projectId: string): Promise<BoardDesignGovernance | null> => (await request<BoardDesignGovernance[]>(`/project_design_governance?project_id=eq.${projectId}&select=approved_concept_asset_id,design_concept_artifact_id,style_guide_artifact_id`))[0] ?? null,
  board: async (projectId: string): Promise<BoardData> => {
    const core = await api.boardCore(projectId);
    const [dependencies, assets] = await Promise.all([api.boardDependencies(core.items), api.boardAssets(projectId)]);
    return { ...core, dependencies, assets };
  },
  activities: (projectId: string) => request<ActivityEvent[]>(`/activity_events?project_id=eq.${projectId}&order=created_at.desc&limit=40`),
  agentMetrics: async (projectId: string) => {
    const rows = await request<AgentMetrics[]>(`/project_agent_metrics?project_id=eq.${projectId}&limit=1`);
    return rows[0] ?? null;
  },
  telemetry: (projectId: string) => request<TelemetryEvent[]>(`/telemetry_events?project_id=eq.${projectId}&order=created_at.desc&limit=100`),
  artifacts: (projectId: string) => request<ProjectArtifact[]>(`/project_artifacts?project_id=eq.${projectId}&order=updated_at.desc`),
  saveProjectArtifact: (record: ProjectArtifact, content: string) => request<ProjectArtifact[]>("/rpc/upsert_project_artifact", {
    method: "POST",
    body: JSON.stringify({
      target_project_id: record.project_id,
      target_artifact_key: record.artifact_key,
      target_artifact_type: record.artifact_type,
      artifact_title: record.title,
      artifact_description: record.description,
      artifact_content: content,
      artifact_status: record.status,
      actor_name: "You",
      artifact_metadata: record.metadata,
    }),
  }),
  moveItem: async (id: string, stage: string) => {
    const items = await request<WorkItem[]>("/rpc/move_work_item", {
      method: "POST",
      body: JSON.stringify({ target_work_item_id: id, target_stage_slug: stage, actor_name: "You" }),
    });
    return items[0] ?? null;
  },
  completeTask: async (id: string, summary?: string) => {
    const items = await request<WorkItem[]>("/rpc/complete_task", {
      method: "POST",
      body: JSON.stringify({
        target_task_id: id,
        actor_name: "You",
        completion_summary: summary ?? null,
      }),
    });
    return items[0] ?? null;
  },
  createItem: async (value: { projectId: string; title: string; description: string; kind: WorkKind; priority: Priority; owner?: string; parentId?: string; acceptanceCriteria?: AcceptanceCriterionInput[]; invariants?: string[]; requiredWorkerCapabilities?: WorkerCapability[]; visualEvidenceRequired?: boolean; designCardType?: DesignCardType; screenNames?: string[] }) => {
    let created = await request<WorkItem[]>("/rpc/create_backlog_item", {
      method: "POST",
      body: JSON.stringify({
        target_project_id: value.projectId,
        item_title: value.title,
        item_description: value.description,
        item_kind: value.kind,
        item_priority: value.priority,
        parent_work_item_id: value.parentId ?? null,
        item_assignee: null,
        item_acceptance_criteria: (value.acceptanceCriteria ?? []).map((criterion) => ({
          statement: criterion.statement,
          verification_method: criterion.verificationMethod,
          verification_ref: criterion.verificationRef,
          expected_result: criterion.expectedResult,
        })),
        item_invariants: value.invariants ?? [],
        actor_name: "You",
      }),
    });
    if (created[0] && value.requiredWorkerCapabilities?.length) {
      created = await request<WorkItem[]>("/rpc/set_work_item_required_capabilities", {
        method: "POST",
        body: JSON.stringify({ target_work_item_id: created[0].id, requested_capabilities: value.requiredWorkerCapabilities, actor_name: "You" }),
      });
    }
    if (created[0] && value.owner?.trim()) created = await api.setWorkItemOwner(created[0].id, value.owner);
    if (value.kind === "story" && created[0] && (value.designCardType || value.screenNames?.length)) {
      return request<WorkItem[]>("/rpc/set_design_card", {
        method: "POST",
        body: JSON.stringify({
          target_work_item_id: created[0].id,
          target_design_card_type: value.designCardType ?? null,
          target_screen_names: value.screenNames ?? [],
          actor_name: "You",
        }),
      });
    }
    if ((value.kind === "story" || value.kind === "feature") && value.visualEvidenceRequired && created[0]) {
      return request<WorkItem[]>("/rpc/set_visual_evidence_requirement", {
        method: "POST",
        body: JSON.stringify({ target_work_item_id: created[0].id, required: true, actor_name: "You" }),
      });
    }
    return created;
  },
  updateItem: (id: string, values: Partial<WorkItem>) => request<WorkItem[]>(`/work_items?id=eq.${id}`, { method: "PATCH", body: JSON.stringify(values) }),
  setWorkItemOwner: (id: string, owner: string | null) => request<WorkItem[]>("/rpc/set_work_item_owner", {
    method: "POST",
    body: JSON.stringify({ target_work_item_id: id, owner_name: owner, actor_name: "You" }),
  }),
  workItemClaimStatus: async (id: string) => {
    const statuses = await request<WorkItemClaimStatus[]>("/rpc/get_work_item_claim_status", {
      method: "POST",
      body: JSON.stringify({ target_work_item_id: id }),
    });
    return statuses[0] ?? null;
  },
  projectWorkers: (projectId: string) => request<AgentWorker[]>(`/project_agent_workers?project_id=eq.${projectId}&status=eq.active&order=display_name.asc`),
  authorizeIdleClaimTakeover: (id: string, workerId: string) => request<WorkItem[]>("/rpc/authorize_idle_claim_takeover", {
    method: "POST",
    body: JSON.stringify({ target_work_item_id: id, new_worker_id: workerId, human_name: "You" }),
  }),
  authorizeIdleClaimRelease: (id: string) => request<WorkItem[]>("/rpc/authorize_idle_claim_release", {
    method: "POST",
    body: JSON.stringify({ target_work_item_id: id, human_name: "You" }),
  }),
  workItem: async (id: string) => {
    const items = await request<WorkItem[]>(`/work_items?id=eq.${id}&limit=1`);
    return items[0] ?? null;
  },
  setDependencies: (id: string, prerequisiteIds: string[]) => request<WorkItemDependency[]>("/rpc/set_work_item_dependencies", {
    method: "POST",
    body: JSON.stringify({ target_work_item_id: id, prerequisite_ids: prerequisiteIds }),
  }),
  setAcceptanceCriteria: (id: string, criteria: AcceptanceCriterionInput[]) => request<WorkItem[]>("/rpc/set_work_item_acceptance_criteria", {
    method: "POST",
    body: JSON.stringify({
      target_work_item_id: id,
      criteria: criteria.map((criterion) => ({
        statement: criterion.statement,
        verification_method: criterion.verificationMethod,
        verification_ref: criterion.verificationRef,
        expected_result: criterion.expectedResult,
      })),
      actor_name: "You",
    }),
  }),
  setInvariants: (id: string, invariants: string[]) => request<WorkItem[]>("/rpc/set_work_item_invariants", {
    method: "POST",
    body: JSON.stringify({ target_work_item_id: id, target_invariants: invariants, actor_name: "You" }),
  }),
  setVisualEvidenceRequirement: (id: string, required: boolean) => request<WorkItem[]>("/rpc/set_visual_evidence_requirement", {
    method: "POST",
    body: JSON.stringify({ target_work_item_id: id, required, actor_name: "You" }),
  }),
  setInteractionEvidenceRequirement: (id: string, required: boolean) => request<WorkItem[]>("/rpc/set_interaction_evidence_requirement", {
    method: "POST",
    body: JSON.stringify({ target_work_item_id: id, required, actor_name: "You" }),
  }),
  setDesignCard: (id: string, designCardType: DesignCardType, screenNames: string[]) => request<WorkItem[]>("/rpc/set_design_card", {
    method: "POST",
    body: JSON.stringify({ target_work_item_id: id, target_design_card_type: designCardType, target_screen_names: screenNames, actor_name: "You" }),
  }),
  workItemContext: (id: string) => request<WorkItemContext>("/rpc/get_governed_work_item_context", {
    method: "POST",
    body: JSON.stringify({ target_work_item_id: id }),
  }),
  designCardCompletionRequirements: (id: string) => request<import("./types").PromotionAcceptanceCriterion[]>("/rpc/design_card_completion_requirements", {
    method: "POST",
    body: JSON.stringify({ target_work_item_id: id }),
  }),
  completeDesignCard: (id: string) => request<WorkItem[]>("/rpc/complete_design_card", {
    method: "POST",
    body: JSON.stringify({ target_work_item_id: id, actor_name: "You" }),
  }),
  workItemActivity: (id: string) => request<ActivityEvent[]>(`/activity_events?work_item_id=eq.${id}&order=created_at.asc`),
  workItemEvidence: (id: string) => request<WorkItemEvidence[]>(`/work_item_evidence?work_item_id=eq.${id}&order=created_at.asc`),
  workItemRegisterEntries: (id: string) => request<WorkItemRegisterEntry[]>(`/work_item_register_entries?work_item_id=eq.${id}&order=entry_type.asc,created_at.asc`),
  workItemAssets: (id: string) => request<WorkItemAsset[]>(`/work_item_assets?work_item_id=eq.${id}&order=is_primary.desc,created_at.desc`),
  attachWorkItemAsset: async (value: { workItemId: string; assetType: WorkItemAssetType; sourceUrl: string; caption?: string; thumbnailUrl?: string; mimeType?: string; filename?: string; viewportWidth?: number; viewportHeight?: number; revision?: string; evidenceId?: string; makePrimary?: boolean; screenName?: string }) => {
    const created = await request<WorkItemAsset[]>("/rpc/attach_work_item_asset", {
      method: "POST",
      body: JSON.stringify({
      target_work_item_id: value.workItemId,
      target_asset_type: value.assetType,
      asset_source_url: value.sourceUrl,
      actor_name: "You",
      asset_caption: value.caption ?? "",
      asset_thumbnail_url: value.thumbnailUrl ?? null,
      asset_mime_type: value.mimeType ?? "image/png",
      asset_filename: value.filename ?? null,
      asset_viewport_width: value.viewportWidth ?? null,
      asset_viewport_height: value.viewportHeight ?? null,
      target_revision: value.revision ?? null,
      target_evidence_id: value.evidenceId ?? null,
      make_primary: value.makePrimary ?? false,
      }),
    });
    if (created[0] && value.screenName) {
      return request<WorkItemAsset[]>("/rpc/set_work_item_asset_screen", {
        method: "POST",
        body: JSON.stringify({ target_asset_id: created[0].id, target_screen_name: value.screenName, actor_name: "You" }),
      });
    }
    return created;
  },
  attachValidationRecording: (value: {
    workItemId: string;
    sourceUrl: string;
    caption: string;
    mimeType: string;
    filename: string;
    viewportWidth?: number;
    viewportHeight?: number;
    revision: string;
    evidenceId: string;
    durationSeconds: number;
    steps: Array<{ atSeconds: number; action: string; expectedResult: string }>;
  }) => request<WorkItemAsset[]>("/rpc/attach_validation_recording", {
    method: "POST",
    body: JSON.stringify({
      target_work_item_id: value.workItemId,
      asset_source_url: value.sourceUrl,
      actor_name: "You",
      target_revision: value.revision,
      target_evidence_id: value.evidenceId,
      recording_caption: value.caption,
      recording_mime_type: value.mimeType,
      recording_filename: value.filename,
      recording_viewport_width: value.viewportWidth ?? null,
      recording_viewport_height: value.viewportHeight ?? null,
      walkthrough_manifest: {
        duration_seconds: value.durationSeconds,
        continuous_capture: true,
        pointer_visible: true,
        playback_speed: 1,
        steps: value.steps.map((step) => ({ at_seconds: step.atSeconds, action: step.action, expected_result: step.expectedResult })),
      },
    }),
  }),
  reviewValidationRecording: (assetId: string, approved: boolean, notes = "") => request<WorkItemAsset[]>("/rpc/review_validation_recording", {
    method: "POST",
    body: JSON.stringify({ target_asset_id: assetId, approved, human_name: "You", review_notes: notes }),
  }),
  approveVisualConcept: (workItemId: string, assetId: string) => request<WorkItemAsset[]>("/rpc/approve_visual_concept", {
    method: "POST", body: JSON.stringify({ target_work_item_id: workItemId, target_asset_id: assetId, actor_name: "You" }),
  }),
  approveScreenMockup: (assetId: string) => request<WorkItemAsset[]>("/rpc/approve_screen_mockup", {
    method: "POST", body: JSON.stringify({ target_asset_id: assetId, actor_name: "You" }),
  }),
  approveDesignConcept: (projectId: string) => request<ProjectArtifact[]>("/rpc/approve_design_concept", {
    method: "POST", body: JSON.stringify({ target_project_id: projectId, actor_name: "You" }),
  }),
  approveDesignSystem: (projectId: string) => request<ProjectArtifact[]>("/rpc/approve_style_guide", {
    method: "POST", body: JSON.stringify({ target_project_id: projectId, actor_name: "You" }),
  }),
  setPrimaryWorkItemAsset: (id: string) => request<WorkItemAsset[]>("/rpc/set_primary_work_item_asset", {
    method: "POST", body: JSON.stringify({ target_asset_id: id, actor_name: "You" }),
  }),
  deleteWorkItemAsset: (id: string) => request<void>("/rpc/delete_work_item_asset", {
    method: "POST", body: JSON.stringify({ target_asset_id: id, actor_name: "You" }),
  }),
  workItemComments: (id: string) => request<WorkItemComment[]>(`/work_item_comments?work_item_id=eq.${id}&order=created_at.asc`),
  addWorkItemComment: (id: string, body: string) => request<WorkItemComment[]>("/rpc/add_work_item_comment", {
    method: "POST",
    body: JSON.stringify({ target_work_item_id: id, comment_body: body, actor_name: "You", target_actor_type: "human" }),
  }),
};
