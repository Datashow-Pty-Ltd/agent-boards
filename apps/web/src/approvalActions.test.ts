import { describe, expect, it } from "vitest";
import { approvalLabel, mockupApprovalsOpen, pendingApprovals } from "./approvalActions";
import type { BoardDesignGovernance, WorkItem, WorkItemAsset } from "./types";

const OPEN: BoardDesignGovernance = { approved_concept_asset_id: "c", design_concept_artifact_id: "d", style_guide_artifact_id: "s" };

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
    recording_review_notes: null, is_primary: false, created_by: "agent", created_at: "2026-11-01T00:00:00Z",
    ...overrides,
  } as WorkItemAsset;
}

const recording = (id: string, overrides: Partial<WorkItemAsset> = {}) =>
  asset(id, { asset_type: "validation_recording", mime_type: "video/mp4", recording_review_status: "pending", ...overrides });

describe("concept cards", () => {
  const concept = item({ design_card_type: "visual_concept" });

  it("offers nothing with fewer than two options, which the server refuses to choose from", () => {
    expect(pendingApprovals(concept, [asset("a")], OPEN)).toEqual([]);
  });

  it("asks for a side-by-side comparison when there are two or more options", () => {
    const result = pendingApprovals(concept, [asset("a"), asset("b", { asset_type: "wireframe" }), asset("r", { approval_status: "rejected" })], null);
    expect(result).toHaveLength(1);
    expect(result[0].kind).toBe("choose_concept");
    expect(approvalLabel(result[0])).toBe("Choose from 3 concepts");
  });

  it("stops asking once a concept has been chosen", () => {
    expect(pendingApprovals(concept, [asset("a", { approval_status: "approved" }), asset("b")], null)).toEqual([]);
  });
});

describe("screen mockups", () => {
  const screens = [
    asset("home", { screen_name: "Home · desktop" }),
    asset("done", { screen_name: "Settings · desktop", approval_status: "approved" }),
    asset("rejected", { screen_name: "Login · desktop", approval_status: "rejected" }),
    asset("ref", { asset_type: "reference", screen_name: "Home · desktop" }),
    asset("loose"),
  ];

  it("lists each unapproved screen once design governance is approved", () => {
    const result = pendingApprovals(item({ design_card_type: "screen_mockup" }), screens, OPEN);
    expect(result.map((entry) => entry.kind === "mockup" && entry.asset.id)).toEqual(["home"]);
  });

  it("offers no mockup approvals the server would refuse before governance is approved", () => {
    for (const governance of [null, { ...OPEN, style_guide_artifact_id: null }, { ...OPEN, approved_concept_asset_id: null }]) {
      expect(mockupApprovalsOpen(governance)).toBe(false);
      expect(pendingApprovals(item({ design_card_type: "screen_mockup" }), screens, governance)).toEqual([]);
    }
  });
});

describe("walkthrough recordings", () => {
  it("offers only the newest pending recording, labelled with its revision and caption", () => {
    const result = pendingApprovals(item(), [
      recording("old", { revision: "1111111aaaa", created_at: "2026-11-01T00:00:00Z" }),
      recording("new", { revision: "2222222bbbb", caption: "Checkout flow", created_at: "2026-11-02T00:00:00Z" }),
      recording("ok", { recording_review_status: "approved", created_at: "2026-11-03T00:00:00Z" }),
      recording("no", { recording_review_status: "rejected", created_at: "2026-11-04T00:00:00Z" }),
    ], null);
    expect(result).toHaveLength(1);
    expect(result[0].kind === "recording" && result[0].asset.id).toBe("new");
    expect(approvalLabel(result[0])).toBe("Walkthrough · 2222222 · Checkout flow");
  });
});

describe("decisions already made", () => {
  it("hides a decided asset immediately so it cannot be submitted twice", () => {
    const assets = [asset("home", { screen_name: "Home" }), recording("r1")];
    expect(pendingApprovals(item(), assets, OPEN, new Set(["home", "r1"]))).toEqual([]);
  });

  it("falls back to the next pending recording once the newest is decided", () => {
    const assets = [recording("a", { created_at: "2026-11-01T00:00:00Z" }), recording("b", { created_at: "2026-11-02T00:00:00Z" })];
    const result = pendingApprovals(item(), assets, null, new Set(["b"]));
    expect(result[0].kind === "recording" && result[0].asset.id).toBe("a");
  });
});

describe("scope", () => {
  it("ignores other cards' assets, finished cards and features", () => {
    const home = asset("a", { screen_name: "Home" });
    expect(pendingApprovals(item(), [asset("x", { work_item_id: "other", screen_name: "Home" })], OPEN)).toEqual([]);
    expect(pendingApprovals(item({ completed_at: "2026-11-11" }), [home], OPEN)).toEqual([]);
    expect(pendingApprovals(item({ kind: "feature" }), [home], OPEN)).toEqual([]);
  });
});
