import type { BoardDesignGovernance, WorkItem, WorkItemAsset } from "./types";

/** A human decision a board card is waiting on, surfaced at the bottom of the card. */
export type PendingApproval =
  | { kind: "choose_concept"; options: WorkItemAsset[] }
  | { kind: "mockup"; asset: WorkItemAsset }
  | { kind: "recording"; asset: WorkItemAsset };

const isDesignOption = (asset: WorkItemAsset) => asset.asset_type === "mockup" || asset.asset_type === "wireframe";

/** Screen mockups can be approved only after the concept, design concept and design system are approved. */
export function mockupApprovalsOpen(governance: BoardDesignGovernance | null | undefined) {
  return Boolean(governance?.approved_concept_asset_id && governance.design_concept_artifact_id && governance.style_guide_artifact_id);
}

/**
 * Pending human approvals for one card that the server will accept now, in
 * the order they gate work: concept choice, screen mockups, walkthroughs.
 *
 * - A concept is chosen by comparing at least two options side by side (the
 *   server refuses fewer), so it is reported as one choose_concept entry that
 *   opens the card rather than a blind one-click approval.
 * - Screen mockups appear only once project design governance is approved.
 * - Only the newest walkthrough recording is offered, and only while pending.
 * - Assets in `decided` (decisions just made on this card) are left out so a
 *   decision cannot be submitted twice while the board reloads.
 */
export function pendingApprovals(
  item: WorkItem,
  assets: WorkItemAsset[],
  governance: BoardDesignGovernance | null | undefined,
  decided: ReadonlySet<string> = new Set(),
): PendingApproval[] {
  if (item.completed_at || item.kind !== "story") return [];
  const own = assets.filter((asset) => asset.work_item_id === item.id && !decided.has(asset.id));
  const pending: PendingApproval[] = [];

  if (item.design_card_type === "visual_concept") {
    const options = assets.filter((asset) => asset.work_item_id === item.id && isDesignOption(asset));
    const chosen = options.some((asset) => asset.approval_status === "approved" || decided.has(asset.id));
    if (!chosen && options.length >= 2) pending.push({ kind: "choose_concept", options });
  } else if (mockupApprovalsOpen(governance)) {
    for (const asset of own) {
      if (isDesignOption(asset) && asset.screen_name && asset.approval_status === "candidate") pending.push({ kind: "mockup", asset });
    }
  }

  // Only the newest recording counts for the interaction gate, so offer it
  // while it is still pending and never fall back to a superseded one.
  const newest = assets
    .filter((asset) => asset.work_item_id === item.id && asset.asset_type === "validation_recording")
    .sort((a, b) => b.created_at.localeCompare(a.created_at))[0];
  if (newest && newest.recording_review_status === "pending" && !decided.has(newest.id)) pending.push({ kind: "recording", asset: newest });
  return pending;
}

export function approvalLabel(approval: PendingApproval) {
  switch (approval.kind) {
    case "choose_concept": return `Choose from ${approval.options.length} concepts`;
    case "mockup": return approval.asset.screen_name ?? "Screen mockup";
    case "recording": {
      const revision = approval.asset.revision ? ` · ${approval.asset.revision.slice(0, 7)}` : "";
      return `Walkthrough${revision}${approval.asset.caption ? ` · ${approval.asset.caption}` : ""}`;
    }
  }
}
