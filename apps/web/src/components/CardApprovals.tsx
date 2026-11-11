import { notifications } from "@mantine/notifications";
import { useEffect, useRef, useState, type SyntheticEvent } from "react";
import { IconCheck, IconEye, IconX } from "@tabler/icons-react";
import { api } from "../api";
import { approvalLabel, pendingApprovals, type PendingApproval } from "../approvalActions";
import type { BoardDesignGovernance, WorkItem, BoardAsset } from "../types";

/** How many approvals a card shows before deferring the rest to the drawer. */
const VISIBLE_APPROVALS = 2;

type Busy = { id: string; approved: boolean } | null;

const keyOf = (approval: PendingApproval) => approval.kind === "choose_concept" ? "choose_concept" : approval.asset.id;

/**
 * Approval actions at the bottom of a board card. Clicks stop at the footer so
 * they never open the drawer; decisions that need a comparison open it.
 */
export function CardApprovals({ item, assets, governance, onOpen, onChanged }: { item: WorkItem; assets: BoardAsset[]; governance: BoardDesignGovernance | null; onOpen?: () => void; onChanged?: () => Promise<void> | void }) {
  const [busy, setBusy] = useState<Busy>(null);
  // Decisions made here, hidden at once so they cannot be submitted twice
  // while the board reloads.
  const [decided, setDecided] = useState<ReadonlySet<string>>(new Set());
  const footer = useRef<HTMLElement>(null);
  const focusAfterDecision = useRef(false);
  // Runs after React commits the render without the decided row, so focus
  // never lands on the button that was just used.
  useEffect(() => {
    if (!focusAfterDecision.current) return;
    focusAfterDecision.current = false;
    const card = document.querySelector(`[data-work-item-id="${CSS.escape(item.id)}"]`);
    const next = card?.querySelector<HTMLElement>(".card-approval-btn.approve:not([disabled]), .card-approval-btn.compare") ?? card?.querySelector<HTMLElement>(".drag-handle");
    next?.focus();
  }, [decided, item.id]);
  const pending = pendingApprovals(item, assets, governance, decided);
  if (!pending.length) return null;
  const visible = pending.slice(0, VISIBLE_APPROVALS);
  const hidden = pending.length - visible.length;

  async function decide(approval: PendingApproval, approved: boolean) {
    if (approval.kind === "choose_concept" || busy) return;
    const { asset } = approval;
    setBusy({ id: asset.id, approved });
    try {
      if (approval.kind === "mockup") await api.approveScreenMockup(asset.id);
      if (approval.kind === "recording") await api.reviewValidationRecording(asset.id, approved);
      // Keep keyboard users in place: the next decision on this card, else its drag handle.
      focusAfterDecision.current = true;
      setDecided((current) => new Set(current).add(asset.id));
      notifications.show({ title: `${approvalLabel(approval)} ${approved ? "approved" : "rejected"}`, message: item.item_key, color: approved ? "accent" : "alert" });
      void onChanged?.();
    } catch (error) {
      notifications.show({ title: "Could not record the decision", message: error instanceof Error ? error.message : String(error), color: "alert" });
    } finally {
      setBusy(null);
    }
  }

  const stop = (event: SyntheticEvent) => event.stopPropagation();
  return (
    <section ref={footer} className="card-approvals" aria-label={`${pending.length} approval${pending.length === 1 ? "" : "s"} waiting on you`} onClick={stop}>
      <div className="card-approvals-title">Needs your approval <span>{pending.length}</span></div>
      {visible.map((approval) => {
        const label = approvalLabel(approval);
        const working = (approved: boolean) => busy?.id === keyOf(approval) && busy.approved === approved;
        return <div className="card-approval" key={keyOf(approval)}>
          <span className="card-approval-label" title={label}>{label}</span>
          {approval.kind === "choose_concept"
            ? <button type="button" className="card-approval-btn compare" onClick={onOpen}><IconEye size={13} />Compare</button>
            : <>
              {onOpen && <button type="button" className="card-approval-btn quiet" aria-label={`Review ${label}`} title="Review in the card" onClick={onOpen}><IconEye size={13} /></button>}
              {approval.kind === "recording" && <button type="button" className="card-approval-btn reject" disabled={busy !== null} aria-busy={working(false)} onClick={() => void decide(approval, false)}><IconX size={13} />{working(false) ? "Saving" : "Reject"}</button>}
              <button type="button" className="card-approval-btn approve" disabled={busy !== null} aria-busy={working(true)} onClick={() => void decide(approval, true)}><IconCheck size={13} />{working(true) ? "Saving" : "Approve"}</button>
            </>}
        </div>;
      })}
      {hidden > 0 && <button type="button" className="card-approvals-more" onClick={onOpen}>+{hidden} more in the card</button>}
    </section>
  );
}
