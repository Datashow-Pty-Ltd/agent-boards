import { describe, expect, it } from "vitest";
import { pendingApprovals } from "./approvalActions";
import type { WorkItem, WorkItemAsset } from "./types";

function item(overrides: Partial<WorkItem> = {}): WorkItem {
  return {
    id: "item", project_id: "p", board_id: "b", parent_id: null, stage_id: "plan", item_key: "AB-1", kind: "story",
    title: "Story", description: "", acceptance_criteria: [], invariants: [], checklist: [], priority: "medium",
    progress: "not_started", execution_state: null, blocked_reason: null, owner: null, assignee: null,
    assignee_worker_id: null, required_worker_capabilities: [], claim_started_at: null, claim_heartbeat_at: null,
    due_date: null, start_date: null, estimate_points: 1, labels: [], visual_evidence_required: false,
    interaction_evidence_required: false, design_card_type: null, screen_names: [], position: 0,
    completed_at: null, created_at: "", updated_at: "",
    ...overrides,
  } as WorkItem;
}

function asset(id: string, overrides: Partial<WorkItemAsset> = {}): WorkItemAsset {
  return {
    id, work_item_id: "item", asset_type: "mockup", source_url: `/uploads/${id}.png`, thumbnail_url: null,
    mime_type: "image/png", filename: null, caption: "", viewport_width: null, viewport_height: null, revision: null,
    screen_name: null, approval_status: "candidate", approved_by: null, approved_at: null, recording_manifest: {},
    recording_review_status: "not_required", recording_reviewed_by: null, recording_reviewed_at: null,
    recording_review_notes: null, is_primary: false, created_by: "agent", created_at: "",
    ...overrides,
  } as WorkItemAsset;
}

describe("pending card approvals", () => {
  it("offers a direct selection for a single concept candidate", () => {
    const result = pendingApprovals(item({ design_card_type: "visual_concept" }), [asset("a")]);
    expect(result).toEqual([{ kind: "concept", asset: expect.objectContaining({ id: "a" }) }]);
  });

  it("asks for a comparison when there are several concept alternatives", () => {
    const result = pendingApprovals(item({ design_card_type: "visual_concept" }), [asset("a"), asset("b"), asset("c", { asset_type: "wireframe" })]);
    expect(result).toHaveLength(1);
    expect(result[0]).toMatchObject({ kind: "choose_concept" });
    expect(result[0].kind === "choose_concept" && result[0].candidates.map((entry) => entry.id)).toEqual(["a", "b", "c"]);
  });

  it("stops asking once a concept has been selected", () => {
    expect(pendingApprovals(item({ design_card_type: "visual_concept" }), [asset("a", { approval_status: "approved" }), asset("b")])).toEqual([]);
  });

  it("lists each unapproved screen mockup but not references or approved screens", () => {
    const result = pendingApprovals(item({ design_card_type: "screen_mockup" }), [
      asset("home", { screen_name: "Home · desktop" }),
      asset("done", { screen_name: "Settings · desktop", approval_status: "approved" }),
      asset("rejected", { screen_name: "Login · desktop", approval_status: "rejected" }),
      asset("ref", { asset_type: "reference", screen_name: "Home · desktop" }),
      asset("loose"),
    ]);
    expect(result.map((entry) => entry.kind !== "choose_concept" && entry.asset.id)).toEqual(["home"]);
  });

  it("asks for pending walkthrough reviews only", () => {
    const result = pendingApprovals(item(), [
      asset("r1", { asset_type: "validation_recording", mime_type: "video/mp4", recording_review_status: "pending" }),
      asset("r2", { asset_type: "validation_recording", mime_type: "video/mp4", recording_review_status: "approved" }),
      asset("r3", { asset_type: "validation_recording", mime_type: "video/mp4", recording_review_status: "rejected" }),
    ]);
    expect(result).toEqual([{ kind: "recording", asset: expect.objectContaining({ id: "r1" }) }]);
  });

  it("ignores other cards' assets, finished cards and features", () => {
    const foreign = asset("x", { work_item_id: "other", screen_name: "Home" });
    expect(pendingApprovals(item(), [foreign])).toEqual([]);
    expect(pendingApprovals(item({ completed_at: "2026-11-11" }), [asset("a", { screen_name: "Home" })])).toEqual([]);
    expect(pendingApprovals(item({ kind: "feature" }), [asset("a", { screen_name: "Home" })])).toEqual([]);
  });
});
