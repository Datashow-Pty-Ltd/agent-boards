import { notifications } from "@mantine/notifications";
import { useState, type SyntheticEvent } from "react";
import { IconCheck, IconEye, IconX } from "@tabler/icons-react";
import { api } from "../api";
import { pendingApprovals, type PendingApproval } from "../approvalActions";
import type { WorkItem, WorkItemAsset } from "../types";

/** How many approvals a card shows before deferring the rest to the drawer. */
const VISIBLE_APPROVALS = 2;

function label(approval: PendingApproval) {
  switch (approval.kind) {
    case "concept": return "Visual concept";
    case "choose_concept": return `${approval.candidates.length} concept alternatives`;
    case "mockup": return approval.asset.screen_name ?? "Screen mockup";
    case "recording": return "Walkthrough recording";
  }
}

function key(approval: PendingApproval) {
  return approval.kind === "choose_concept" ? "choose_concept" : `${approval.kind}:${approval.asset.id}`;
}

/**
 * Approval actions at the bottom of a board card. Every button stops the
 * click from opening the drawer; decisions that need a comparison open it.
 */
export function CardApprovals({ item, assets, onOpen, onChanged }: { item: WorkItem; assets: WorkItemAsset[]; onOpen?: () => void; onChanged?: () => Promise<void> | void }) {
  const [busy, setBusy] = useState<string | null>(null);
  const pending = pendingApprovals(item, assets);
  if (!pending.length) return null;
  const visible = pending.slice(0, VISIBLE_APPROVALS);
  const hidden = pending.length - visible.length;

  async function decide(approval: PendingApproval, approved: boolean) {
    if (approval.kind === "choose_concept") return;
    const id = key(approval);
    setBusy(id);
    try {
      if (approval.kind === "concept") await api.approveVisualConcept(item.id, approval.asset.id);
      if (approval.kind === "mockup") await api.approveScreenMockup(approval.asset.id);
      if (approval.kind === "recording") await api.reviewValidationRecording(approval.asset.id, approved);
      notifications.show({
        title: approved ? `${label(approval)} approved` : `${label(approval)} rejected`,
        message: item.item_key,
        color: approved ? "accent" : "alert",
      });
      await onChanged?.();
    } catch (error) {
      notifications.show({ title: "Could not record the decision", message: error instanceof Error ? error.message : String(error), color: "alert" });
    } finally {
      setBusy(null);
    }
  }

  const stop = (event: SyntheticEvent) => event.stopPropagation();
  return (
    <section className="card-approvals" aria-label={`${pending.length} approval${pending.length === 1 ? "" : "s"} waiting on you`} onClick={stop} onPointerDown={stop} onKeyDown={stop}>
      <div className="card-approvals-title">Needs your approval <span>{pending.length}</span></div>
      {visible.map((approval) => {
        const id = key(approval);
        const working = busy === id;
        return <div className="card-approval" key={id}>
          <span className="card-approval-label" title={label(approval)}>{label(approval)}</span>
          {approval.kind === "choose_concept"
            ? <button type="button" className="card-approval-btn" onClick={onOpen}><IconEye size={12} />Compare</button>
            : <>
              {onOpen && <button type="button" className="card-approval-btn quiet" aria-label={`Review ${label(approval)}`} title="Review in the card" onClick={onOpen}><IconEye size={12} /></button>}
              {approval.kind === "recording" && <button type="button" className="card-approval-btn reject" disabled={busy !== null} onClick={() => void decide(approval, false)}><IconX size={12} />Reject</button>}
              <button type="button" className="card-approval-btn approve" disabled={busy !== null} aria-busy={working} onClick={() => void decide(approval, true)}><IconCheck size={12} />{working ? "Saving" : approval.kind === "concept" ? "Select" : "Approve"}</button>
            </>}
        </div>;
      })}
      {hidden > 0 && <button type="button" className="card-approvals-more" onClick={onOpen}>+{hidden} more in the card</button>}
    </section>
  );
}
