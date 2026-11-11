type Row = Record<string, unknown>;

/** Card fields an agent needs to choose and route work; full bodies come from get_work_item_context. */
const SUMMARY_ITEM_FIELDS = [
  "id", "item_key", "kind", "title", "parent_id", "stage_id", "priority", "progress",
  "execution_state", "blocked_reason", "owner", "assignee", "assignee_worker_id",
  "claim_started_at", "claim_heartbeat_at", "position", "screen_names",
  "required_worker_capabilities", "visual_evidence_required", "interaction_evidence_required",
  "design_card_type", "completed_at", "updated_at",
] as const;

const SUMMARY_STAGE_FIELDS = ["id", "slug", "title", "position", "responsible_actor", "wip_limit", "allowed_transitions"] as const;

function pick(row: Row, fields: readonly string[]): Row {
  const picked: Row = {};
  for (const field of fields) if (field in row) picked[field] = row[field];
  return picked;
}

interface FullBoard {
  project: unknown;
  repository: unknown;
  board: unknown;
  stages: unknown;
  items: unknown;
  dependencies: unknown;
  evidence: unknown;
  visualAssets: unknown;
  metrics: unknown;
  deliveryStatuses: unknown;
  visualCompliance: unknown;
}

const rows = (value: unknown): Row[] => (Array.isArray(value) ? (value as Row[]) : []);

/**
 * A compact board: card headers with stage slugs, claim state, delivery and
 * visual-compliance status, prerequisite edges and a per-card evidence tally
 * (latest outcome per evidence type). Descriptions, acceptance criteria,
 * evidence bodies, compliance details and assets are omitted.
 */
export function summarizeBoard(full: FullBoard) {
  const stages = rows(full.stages);
  const stageSlug = new Map(stages.map((stage) => [stage.id, stage.slug]));
  const latestEvidence = new Map<unknown, Row>();
  // Evidence arrives newest first, so the first row per type is the latest.
  for (const evidence of rows(full.evidence)) {
    const tally = latestEvidence.get(evidence.work_item_id) ?? {};
    const type = String(evidence.evidence_type);
    if (!(type in tally)) tally[type] = { outcome: evidence.outcome, revision: evidence.revision };
    latestEvidence.set(evidence.work_item_id, tally);
  }
  const delivery = new Map(rows(full.deliveryStatuses).map((status) => [status.work_item_id, status]));
  const compliance = new Map(rows(full.visualCompliance).map((status) => [status.work_item_id, status]));
  const items = rows(full.items).map((item) => {
    const status = delivery.get(item.id);
    const visual = compliance.get(item.id);
    return {
      ...pick(item, SUMMARY_ITEM_FIELDS),
      stage: stageSlug.get(item.stage_id) ?? null,
      latest_evidence: latestEvidence.get(item.id) ?? {},
      ...(status ? pick(status, ["delivery_complete", "visual_compliant"]) : {}),
      ...(visual ? { visual_compliance: pick(visual, ["compliant", "failed_screen_count", "remediation_work_item_id"]) } : {}),
    };
  });
  const dependencies = rows(full.dependencies).map((edge) => pick(edge, ["work_item_id", "depends_on_work_item_id"]));
  return {
    detail: "summary",
    note: "Compact board. Call get_work_item_context for a card's description, acceptance criteria and evidence, or get_board with detail \"full\" for every field.",
    project: pick((full.project ?? {}) as Row, ["id", "project_key", "name", "status", "claim_idle_timeout_minutes"]),
    repository: full.repository,
    board: pick((full.board ?? {}) as Row, ["id", "name"]),
    stages: stages.map((stage) => pick(stage, SUMMARY_STAGE_FIELDS)),
    items,
    dependencies,
    metrics: full.metrics,
  };
}
