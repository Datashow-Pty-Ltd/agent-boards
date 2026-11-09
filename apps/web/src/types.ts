export type Priority = "urgent" | "high" | "medium" | "low";
export type WorkKind = "feature" | "story" | "task";
export type WorkerCapability = "code_execution" | "git" | "browser_automation" | "screenshot_capture" | "screen_recording" | "image_generation" | "visual_comparison";
export type DesignCardType = "visual_concept" | "screen_mockup" | null;
export type ExecutionState = "queued" | "running" | "waiting_for_human" | "blocked" | "failed" | "complete" | "cancelled" | null;
export type AcceptanceVerificationMethod = "automated_test" | "command" | "http_assertion" | "database_assertion" | "visual_baseline";
export type WorkItemAssetType = "reference" | "mockup" | "wireframe" | "implementation_screenshot" | "visual_validation" | "visual_diff" | "validation_recording";
export interface AcceptanceCriterionInput {
  statement: string;
  verificationMethod: AcceptanceVerificationMethod;
  verificationRef: string;
  expectedResult: string;
}
export interface AcceptanceCriterion {
  id: string;
  statement: string;
  verification_method: AcceptanceVerificationMethod | "unspecified";
  verification_ref: string;
  expected_result: string;
  status: "pending" | "passed" | "failed";
  revision: string | null;
  evidence_id: string | null;
}

export interface ProjectSummary {
  project_id: string;
  project_key: string;
  name: string;
  description: string;
  owner: string;
  status: string;
  start_date: string;
  target_date: string | null;
  total_items: number;
  completed_items: number;
  running_items: number;
  blocked_items: number;
  total_points: number;
  completed_points: number;
  tokens: number;
  estimated_cost_usd: number;
  updated_at: string;
  raw_completed_items: number;
  noncompliant_visual_story_count: number;
  visual_compliance_ready: boolean;
}

export interface ProjectRepository {
  id: string;
  project_id: string;
  provider: "github" | "gitlab" | "bitbucket" | "other";
  repository_url: string;
  full_name: string;
  default_branch: string;
  created_by: string;
  created_at: string;
  updated_at: string;
}

export interface Board { id: string; project_id: string; name: string; description: string; }
export interface Stage {
  id: string;
  board_id: string;
  slug: string;
  title: string;
  position: number;
  bucket_key: string;
  bucket_title: string;
  purpose: string;
  responsible_actor: string;
  wip_limit: number | null;
  entry_criteria: string[];
  exit_criteria: string[];
  allowed_transitions: string[];
}
export interface WorkItem {
  id: string;
  project_id: string;
  board_id: string;
  parent_id: string | null;
  stage_id: string;
  item_key: string;
  kind: WorkKind;
  title: string;
  description: string;
  acceptance_criteria: AcceptanceCriterion[];
  invariants: string[];
  checklist: Array<{ label: string; checked: boolean }>;
  priority: Priority;
  progress: "not_started" | "in_progress" | "completed";
  execution_state: ExecutionState;
  blocked_reason: string | null;
  owner: string | null;
  assignee: string | null;
  assignee_worker_id: string | null;
  required_worker_capabilities: WorkerCapability[];
  claim_started_at: string | null;
  claim_heartbeat_at: string | null;
  due_date: string | null;
  start_date: string | null;
  estimate_points: number;
  labels: string[];
  visual_evidence_required: boolean;
  interaction_evidence_required: boolean;
  design_card_type: DesignCardType;
  screen_names: string[];
  position: number;
  completed_at: string | null;
  created_at: string;
  updated_at: string;
}
export interface WorkItemClaimStatus {
  work_item_id: string;
  owner: string | null;
  active_worker: string | null;
  active_worker_id: string | null;
  execution_state: string | null;
  claim_started_at: string | null;
  last_heartbeat_at: string | null;
  idle_seconds: number;
  timeout_seconds: number;
  takeover_eligible: boolean;
}
export interface AgentWorker {
  worker_id: string;
  project_id: string;
  handle: string;
  display_name: string;
  client_type: "codex" | "claude" | "other";
  capabilities: WorkerCapability[];
  status: "active" | "revoked";
  last_seen_at: string;
  created_at: string;
  active_claims: number;
}
export interface WorkItemDependency {
  work_item_id: string;
  depends_on_work_item_id: string;
  created_at: string;
}
export interface PromotionAcceptanceCriterion {
  requirement: string;
  satisfied: boolean;
  blocking?: boolean;
  policy?: "recommended" | "required" | "waived";
  description?: string;
  waiver_reason?: string | null;
  revision?: string | null;
  remaining?: number;
}
export interface WorkItemContext {
  story: WorkItem;
  tasks: Array<Pick<WorkItem, "id" | "title" | "description" | "checklist" | "progress" | "execution_state"> & { key: string }>;
  invariants: string[];
  story_acceptance_criteria: AcceptanceCriterion[];
  visual_assets: WorkItemAsset[];
  visual_evidence_required: boolean;
  visual_requirement_source: "story" | "feature" | null;
  design_governance: {
    design_card_type: DesignCardType;
    screen_names: string[];
    concept_design_card_id?: string | null;
    approved_concept_asset_id?: string | null;
    concept_approved_by?: string | null;
    concept_approved_at?: string | null;
    design_concept_artifact_id?: string | null;
    design_concept_approved_by?: string | null;
    design_concept_approved_at?: string | null;
    style_guide_artifact_id?: string | null;
    style_guide_approved_by?: string | null;
    style_guide_approved_at?: string | null;
  };
  promotion: {
    current_stage: Pick<Stage, "slug" | "title" | "purpose" | "entry_criteria" | "exit_criteria">;
    allowed_next_stages: Array<Pick<Stage, "slug" | "title" | "entry_criteria">>;
    acceptance_criteria: PromotionAcceptanceCriterion[];
    ready: boolean;
  };
}
export interface WorkItemAsset {
  id: string;
  project_id: string;
  work_item_id: string;
  evidence_id: string | null;
  asset_type: WorkItemAssetType;
  source_url: string;
  thumbnail_url: string | null;
  mime_type: string;
  filename: string | null;
  caption: string;
  viewport_width: number | null;
  viewport_height: number | null;
  revision: string | null;
  screen_name: string | null;
  approval_status: "candidate" | "approved" | "rejected";
  approved_by: string | null;
  approved_at: string | null;
  recording_manifest: {
    duration_seconds?: number;
    continuous_capture?: boolean;
    pointer_visible?: boolean;
    playback_speed?: number;
    steps?: Array<{ at_seconds: number; action: string; expected_result: string }>;
  };
  recording_review_status: "not_required" | "pending" | "approved" | "rejected";
  recording_reviewed_by: string | null;
  recording_reviewed_at: string | null;
  recording_review_notes: string | null;
  is_primary: boolean;
  created_by: string;
  created_at: string;
}
export interface ActivityEvent {
  id: string;
  project_id: string;
  work_item_id: string | null;
  event_type: string;
  actor_type: "human" | "agent" | "system";
  actor_name: string;
  summary: string;
  details: Record<string, unknown>;
  created_at: string;
}
export interface WorkItemEvidence {
  id: string;
  project_id: string;
  work_item_id: string;
  evidence_type: "analysis" | "plan" | "implementation" | "test" | "unit_test" | "review" | "merge" | "regression";
  outcome: "recorded" | "passed" | "failed" | "approved" | "rejected" | "merged";
  revision: string | null;
  summary: string;
  url: string | null;
  details: Record<string, unknown>;
  actor_name: string;
  created_at: string;
}
export interface WorkItemComment {
  id: string;
  work_item_id: string;
  actor_type: "human" | "agent" | "system";
  actor_name: string;
  body: string;
  created_at: string;
}
export interface TelemetryEvent {
  id: string;
  project_id: string;
  work_item_id: string | null;
  agent_name: string;
  provider: string | null;
  model: string | null;
  status: string;
  duration_ms: number;
  input_tokens: number;
  output_tokens: number;
  estimated_cost_usd: number;
  created_at: string;
}
export interface AgentMetrics {
  project_id: string;
  tracking_started_at: string;
  claim_session_count: number;
  open_claim_session_count: number;
  closed_claim_session_count: number;
  claimed_duration_ms: number;
  input_tokens: number;
  output_tokens: number;
  estimated_cost_usd: number;
  usage_reported_sessions: number;
  token_reported_sessions: number;
  cost_reported_sessions: number;
}
export interface ProjectArtifact {
  id: string;
  project_id: string;
  artifact_key: string;
  artifact_type: string;
  title: string;
  description: string;
  content: string;
  metadata: Record<string, unknown>;
  status: "draft" | "current" | "superseded";
  version: number;
  created_by: string;
  created_at: string;
  updated_at: string;
}
export interface BoardData { board: Board; stages: Stage[]; items: WorkItem[]; dependencies: WorkItemDependency[]; assets: WorkItemAsset[]; }
