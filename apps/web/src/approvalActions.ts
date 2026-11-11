import type { WorkItem, WorkItemAsset } from "./types";

/** A human decision a board card is waiting on, surfaced at the bottom of the card. */
export type PendingApproval =
  | { kind: "concept"; asset: WorkItemAsset }
  | { kind: "choose_concept"; candidates: WorkItemAsset[] }
  | { kind: "mockup"; asset: WorkItemAsset }
  | { kind: "recording"; asset: WorkItemAsset };

const isMockup = (asset: WorkItemAsset) => asset.asset_type === "mockup" || asset.asset_type === "wireframe";

/**
 * Pending human approvals for one card, in the order they gate work: concept
 * selection, then screen mockups, then walkthrough recordings. Decisions that
 * need a side-by-side comparison (several concept alternatives) are reported
 * as a single choose_concept entry so the card can send the person to the
 * drawer instead of approving blind.
 */
export function pendingApprovals(item: WorkItem, assets: WorkItemAsset[]): PendingApproval[] {
  if (item.completed_at || item.kind !== "story") return [];
  const own = assets.filter((asset) => asset.work_item_id === item.id);
  const pending: PendingApproval[] = [];

  if (item.design_card_type === "visual_concept") {
    const concepts = own.filter(isMockup);
    const candidates = concepts.filter((asset) => asset.approval_status === "candidate");
    const decided = concepts.some((asset) => asset.approval_status === "approved");
    if (!decided && candidates.length === 1) pending.push({ kind: "concept", asset: candidates[0] });
    if (!decided && candidates.length > 1) pending.push({ kind: "choose_concept", candidates });
  } else {
    for (const asset of own) {
      if (isMockup(asset) && asset.screen_name && asset.approval_status === "candidate") pending.push({ kind: "mockup", asset });
    }
  }

  for (const asset of own) {
    if (asset.asset_type === "validation_recording" && asset.recording_review_status === "pending") pending.push({ kind: "recording", asset });
  }
  return pending;
}
