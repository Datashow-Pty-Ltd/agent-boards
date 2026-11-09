import { ActionIcon, Button, Drawer, FileInput, Group, Modal, MultiSelect, Select, Switch, Textarea, TextInput } from "@mantine/core";
import { notifications } from "@mantine/notifications";
import { IconArrowRight, IconCheck, IconLock, IconPhoto, IconStar, IconTrash, IconVideo } from "@tabler/icons-react";
import { useEffect, useMemo, useState } from "react";
import { Link } from "react-router";
import { api } from "../api";
import type { AcceptanceCriterionInput, AcceptanceVerificationMethod, ActivityEvent, DesignCardType, ExecutionState, Priority, PromotionAcceptanceCriterion, Stage, WorkItem, WorkItemAsset, WorkItemAssetType, WorkItemComment, WorkItemContext, WorkItemDependency, WorkItemEvidence } from "../types";

const acceptanceVerificationMethods: Array<{ value: AcceptanceVerificationMethod; label: string }> = [
  { value: "automated_test", label: "Automated test" },
  { value: "command", label: "Command" },
  { value: "http_assertion", label: "HTTP assertion" },
  { value: "database_assertion", label: "Database assertion" },
  { value: "visual_baseline", label: "Visual baseline" },
];

function emptyAcceptanceCriterion(): AcceptanceCriterionInput {
  return { statement: "", verificationMethod: "automated_test", verificationRef: "", expectedResult: "" };
}

type Props = {
  item: WorkItem | null;
  items: WorkItem[];
  stages: Stage[];
  dependencies: WorkItemDependency[];
  opened: boolean;
  onClose: () => void;
  onChanged: () => void | Promise<void>;
};

function dateLabel(value: string | null) {
  return value ? new Date(`${value}T00:00:00`).toLocaleDateString() : "Not set";
}

function timestampLabel(value: string) {
  return new Date(value).toLocaleString([], { dateStyle: "medium", timeStyle: "short" });
}

function shortRevision(value: string | null) {
  return value ? value.slice(0, 8) : null;
}

const visualAssetTypes: Array<{ value: WorkItemAssetType; label: string }> = [
  { value: "reference", label: "Reference" },
  { value: "mockup", label: "Mockup" },
  { value: "wireframe", label: "Wireframe" },
  { value: "implementation_screenshot", label: "Implementation screenshot" },
  { value: "visual_validation", label: "Visual validation" },
  { value: "visual_diff", label: "Visual diff" },
  { value: "validation_recording", label: "Validation recording" },
];

export function ItemDrawer({ item, items, stages, dependencies, opened, onClose, onChanged }: Props) {
  const [title, setTitle] = useState("");
  const [description, setDescription] = useState("");
  const [assignee, setAssignee] = useState("");
  const [priority, setPriority] = useState<Priority>("medium");
  const [execution, setExecution] = useState<ExecutionState>(null);
  const [blockedReason, setBlockedReason] = useState("");
  const [parentId, setParentId] = useState<string | null>(null);
  const [prerequisiteIds, setPrerequisiteIds] = useState<string[]>([]);
  const [newTaskTitle, setNewTaskTitle] = useState("");
  const [acceptanceCriteria, setAcceptanceCriteria] = useState<AcceptanceCriterionInput[]>([]);
  const [invariants, setInvariants] = useState("");
  const [workContext, setWorkContext] = useState<WorkItemContext | null>(null);
  const [designCompletionRequirements, setDesignCompletionRequirements] = useState<PromotionAcceptanceCriterion[]>([]);
  const [activity, setActivity] = useState<ActivityEvent[]>([]);
  const [evidence, setEvidence] = useState<WorkItemEvidence[]>([]);
  const [comments, setComments] = useState<WorkItemComment[]>([]);
  const [assets, setAssets] = useState<WorkItemAsset[]>([]);
  const [visualEvidenceRequired, setVisualEvidenceRequired] = useState(false);
  const [interactionEvidenceRequired, setInteractionEvidenceRequired] = useState(false);
  const [designCardType, setDesignCardType] = useState<DesignCardType>(null);
  const [screenNames, setScreenNames] = useState("");
  const [visualAssetType, setVisualAssetType] = useState<WorkItemAssetType>("reference");
  const [visualFile, setVisualFile] = useState<File | null>(null);
  const [visualCaption, setVisualCaption] = useState("");
  const [visualRevision, setVisualRevision] = useState("");
  const [visualScreenName, setVisualScreenName] = useState<string | null>(null);
  const [recordingSteps, setRecordingSteps] = useState("");
  const [activeVisual, setActiveVisual] = useState<WorkItemAsset | null>(null);
  const [newComment, setNewComment] = useState("");
  const [saving, setSaving] = useState(false);
  const [addingTask, setAddingTask] = useState(false);
  const [addingComment, setAddingComment] = useState(false);
  const [addingVisual, setAddingVisual] = useState(false);

  useEffect(() => {
    if (!item) return;
    setTitle(item.title);
    setDescription(item.description);
    setAssignee(item.assignee ?? "");
    setPriority(item.priority);
    setExecution(item.execution_state);
    setBlockedReason(item.blocked_reason ?? "");
    setParentId(item.parent_id);
    setPrerequisiteIds(dependencies.filter((dependency) => dependency.work_item_id === item.id).map((dependency) => dependency.depends_on_work_item_id));
    setAcceptanceCriteria(item.acceptance_criteria.map((criterion) => ({
      statement: criterion.statement,
      verificationMethod: criterion.verification_method === "unspecified" ? "automated_test" : criterion.verification_method,
      verificationRef: criterion.verification_ref,
      expectedResult: criterion.expected_result,
    })));
    setInvariants(item.invariants.join("\n"));
    setVisualEvidenceRequired(item.visual_evidence_required);
    setInteractionEvidenceRequired(item.interaction_evidence_required);
    setDesignCardType(item.design_card_type);
    setScreenNames(item.screen_names.join("\n"));
    setWorkContext(null);
    setDesignCompletionRequirements([]);
    setActivity([]);
    setEvidence([]);
    setComments([]);
    setAssets([]);
    void Promise.all([
      item.kind === "story" ? api.workItemContext(item.id) : Promise.resolve(null),
      item.kind === "story" && item.design_card_type ? api.designCardCompletionRequirements(item.id) : Promise.resolve([]),
      api.workItemActivity(item.id),
      api.workItemEvidence(item.id),
      api.workItemComments(item.id),
      api.workItemAssets(item.id),
    ]).then(([context, nextDesignRequirements, nextActivity, nextEvidence, nextComments, nextAssets]) => {
      setWorkContext(context);
      setDesignCompletionRequirements(nextDesignRequirements);
      setActivity(nextActivity);
      setEvidence(nextEvidence);
      setComments(nextComments);
      setAssets(nextAssets);
    }).catch(() => {
      setWorkContext(null);
      setDesignCompletionRequirements([]);
      setActivity([]);
      setEvidence([]);
      setComments([]);
      setAssets([]);
    });
    setNewTaskTitle("");
    setNewComment("");
    setVisualFile(null);
    setVisualCaption("");
    setVisualRevision("");
    setVisualScreenName(null);
    setRecordingSteps("");
    setActiveVisual(null);
  }, [item, dependencies]);

  const itemById = useMemo(() => new Map(items.map((entry) => [entry.id, entry])), [items]);
  if (!item) return null;

  const childTasks = items.filter((entry) => entry.kind === "task" && entry.parent_id === item.id);
  const inheritedPrerequisiteIds = item.kind === "story" && item.parent_id
    ? dependencies.filter((dependency) => dependency.work_item_id === item.parent_id).map((dependency) => dependency.depends_on_work_item_id)
    : [];
  const effectivePrerequisiteIds = [...new Set([...prerequisiteIds, ...inheritedPrerequisiteIds])];
  const prerequisiteItems = effectivePrerequisiteIds.map((id) => itemById.get(id)).filter((entry): entry is WorkItem => Boolean(entry));
  const incompletePrerequisites = prerequisiteItems.filter((entry) => !entry.completed_at && entry.progress !== "completed");
  const parentOptions = item.kind === "story" ? items.filter((entry) => entry.kind === "feature") : items.filter((entry) => entry.kind === "story");
  const dependencyOptions = items.filter((entry) => entry.kind === item.kind && entry.id !== item.id);
  const parent = parentId ? itemById.get(parentId) : null;
  const stage = stages.find((entry) => entry.id === item.stage_id);
  const canEditAcceptance = item.kind === "story" && ["backlog", "analyse", "plan"].includes(stage?.slug ?? "");
  const canEditVisualRequirement = (item.kind === "story" || item.kind === "feature") && ["backlog", "analyse", "plan"].includes(stage?.slug ?? "");
  const inheritsVisualRequirement = item.kind === "story" && Boolean(parent?.visual_evidence_required) && !item.visual_evidence_required;
  const acceptanceValid = acceptanceCriteria.length > 0 && acceptanceCriteria.every((criterion) =>
    criterion.statement.trim() && criterion.verificationRef.trim() && criterion.expectedResult.trim());
  const stageTransitions = activity.filter((event) => event.event_type === "work_item.moved");
  const mergedEvidence = [...evidence].reverse().find((entry) => entry.evidence_type === "merge" && entry.outcome === "merged");
  const failedEvidence = [...evidence].reverse().find((entry) => entry.outcome === "failed" || entry.outcome === "rejected");
  const deliveryGate = failedEvidence
    ? "Failed"
    : item.progress === "completed" && mergedEvidence
      ? "Passed"
      : workContext?.promotion.ready
        ? "Ready for promotion"
        : incompletePrerequisites.length
          ? "Blocked"
          : "In progress";
  const timeline = [
    ...activity.filter((event) => event.event_type !== "work_item.evidence_recorded" && event.event_type !== "work_item.commented").map((event) => ({ id: event.id, kind: "event" as const, createdAt: event.created_at, event })),
    ...evidence.map((entry) => ({ id: entry.id, kind: "evidence" as const, createdAt: entry.created_at, evidence: entry })),
    ...comments.map((comment) => ({ id: comment.id, kind: "comment" as const, createdAt: comment.created_at, comment })),
  ].sort((a, b) => new Date(a.createdAt).getTime() - new Date(b.createdAt).getTime());

  async function save() {
    setSaving(true);
    try {
      await api.updateItem(item!.id, {
        title: title.trim(), description, parent_id: parentId, assignee: assignee || null, priority,
        execution_state: execution, blocked_reason: blockedReason || null,
      });
      if (item!.kind === "story" || item!.kind === "feature") await api.setDependencies(item!.id, prerequisiteIds);
      if ((item!.kind === "story" || item!.kind === "feature") && visualEvidenceRequired !== item!.visual_evidence_required) {
        await api.setVisualEvidenceRequirement(item!.id, visualEvidenceRequired);
      }
      if (item!.kind === "story" && interactionEvidenceRequired !== item!.interaction_evidence_required) {
        await api.setInteractionEvidenceRequirement(item!.id, interactionEvidenceRequired);
      }
      if (item!.kind === "story" && (visualEvidenceRequired || inheritsVisualRequirement)) {
        await api.setDesignCard(item!.id, designCardType, screenNames.split("\n").map((entry) => entry.trim()).filter(Boolean));
      }
      if (canEditAcceptance) {
        if (!acceptanceValid) throw new Error("Every story needs at least one deterministic acceptance criterion.");
        await api.setAcceptanceCriteria(item!.id, acceptanceCriteria.map((criterion) => ({
          ...criterion,
          statement: criterion.statement.trim(),
          verificationRef: criterion.verificationRef.trim(),
          expectedResult: criterion.expectedResult.trim(),
        })));
        await api.setInvariants(item!.id, invariants.split("\n").map((entry) => entry.trim()).filter(Boolean));
      }
      await onChanged();
      notifications.show({ title: "Work item updated", message: item!.item_key, color: "accent" });
    } catch (error) {
      notifications.show({ title: "Could not update work item", message: error instanceof Error ? error.message : String(error), color: "alert" });
    } finally { setSaving(false); }
  }

  async function addTask() {
    if (!newTaskTitle.trim()) return;
    setAddingTask(true);
    try {
      await api.createItem({ projectId: item!.project_id, title: newTaskTitle.trim(), description: "", kind: "task", priority: item!.priority, parentId: item!.id });
      setNewTaskTitle("");
      await onChanged();
      notifications.show({ title: "Task added", message: `Added to ${item!.item_key}`, color: "accent" });
    } catch (error) {
      notifications.show({ title: "Could not add task", message: error instanceof Error ? error.message : String(error), color: "alert" });
    } finally { setAddingTask(false); }
  }

  async function addComment() {
    if (!newComment.trim()) return;
    setAddingComment(true);
    try {
      const [comment] = await api.addWorkItemComment(item!.id, newComment.trim());
      if (comment) setComments((current) => [...current, comment]);
      setNewComment("");
      notifications.show({ title: "Comment added", message: item!.item_key, color: "accent" });
    } catch (error) {
      notifications.show({ title: "Could not add comment", message: error instanceof Error ? error.message : String(error), color: "alert" });
    } finally { setAddingComment(false); }
  }

  async function addVisual() {
    if (!visualFile) return;
    const isRecording = visualAssetType === "validation_recording";
    const needsRevision = ["implementation_screenshot", "visual_validation", "visual_diff", "validation_recording"].includes(visualAssetType);
    if (needsRevision && !visualRevision.trim()) {
      notifications.show({ title: "Revision required", message: "Implementation and validation media must identify the exact revision.", color: "alert" });
      return;
    }
    if (isRecording && !visualFile.type.startsWith("video/")) {
      notifications.show({ title: "Video required", message: "Choose a video file for a validation recording.", color: "alert" });
      return;
    }
    if (!isRecording && !visualFile.type.startsWith("image/")) {
      notifications.show({ title: "Image required", message: "Choose an image for this visual asset type.", color: "alert" });
      return;
    }
    const maxFileSize = isRecording ? 50 * 1024 * 1024 : 8 * 1024 * 1024;
    if (visualFile.size > maxFileSize) {
      notifications.show({
        title: "File is too large",
        message: isRecording ? "Use a validation recording smaller than 50 MB." : "Use an image smaller than 8 MB.",
        color: "alert",
      });
      return;
    }
    const linkedEvidence = isRecording
      ? [...evidence].reverse().find((entry) => entry.evidence_type === "test" && entry.revision === visualRevision.trim())
      : undefined;
    if (isRecording && !linkedEvidence) {
      notifications.show({
        title: "Validation evidence required",
        message: "Record the validation result for this revision before attaching its recording.",
        color: "alert",
      });
      return;
    }
    const parsedSteps = isRecording ? recordingSteps.split("\n").filter((line) => line.trim()).map((line) => {
      const [at, action, expectedResult] = line.split("|").map((part) => part.trim());
      return { atSeconds: Number(at), action, expectedResult };
    }) : [];
    if (isRecording && (parsedSteps.length < 2 || parsedSteps.some((step) => !Number.isFinite(step.atSeconds) || step.atSeconds < 0 || !step.action || !step.expectedResult))) {
      notifications.show({
        title: "Walkthrough steps required",
        message: "Add at least two lines as: seconds | action | expected visible result.",
        color: "alert",
      });
      return;
    }
    setAddingVisual(true);
    let uploadedUrl: string | null = null;
    try {
      const uploaded = await api.uploadMedia(visualFile);
      uploadedUrl = uploaded.url;
      const [created] = isRecording
        ? await api.attachValidationRecording({
          workItemId: item!.id,
          sourceUrl: uploaded.url,
          caption: visualCaption.trim(),
          mimeType: visualFile.type,
          filename: visualFile.name,
          revision: visualRevision.trim(),
          evidenceId: linkedEvidence!.id,
          durationSeconds: uploaded.durationSeconds ?? 0,
          steps: parsedSteps,
        })
        : await api.attachWorkItemAsset({
          workItemId: item!.id,
          assetType: visualAssetType,
          sourceUrl: uploaded.url,
          caption: visualCaption.trim(),
          mimeType: visualFile.type || "image/png",
          filename: visualFile.name,
          revision: visualRevision.trim() || undefined,
          makePrimary: assets.every((asset) => asset.asset_type === "validation_recording"),
          screenName: ["mockup", "wireframe"].includes(visualAssetType) ? visualScreenName ?? undefined : undefined,
        });
      if (created) setAssets((current) => [created, ...current.map((asset) => ({ ...asset, is_primary: created.is_primary ? false : asset.is_primary }))]);
      setVisualFile(null); setVisualCaption(""); setVisualRevision(""); setVisualScreenName(null); setRecordingSteps("");
      await onChanged();
      notifications.show({ title: isRecording ? "Validation recording attached" : "Visual attached", message: visualFile.name, color: "accent" });
    } catch (error) {
      if (uploadedUrl) await api.deleteUploadedMedia(uploadedUrl).catch(() => undefined);
      notifications.show({ title: "Could not attach visual", message: error instanceof Error ? error.message : String(error), color: "alert" });
    } finally { setAddingVisual(false); }
  }

  async function reviewRecording(asset: WorkItemAsset, approved: boolean) {
    try {
      const [updated] = await api.reviewValidationRecording(asset.id, approved);
      if (updated) setAssets((current) => current.map((entry) => entry.id === updated.id ? updated : entry));
      setWorkContext(await api.workItemContext(item!.id));
      await onChanged();
      notifications.show({ title: approved ? "Walkthrough approved" : "Walkthrough rejected", message: item!.item_key, color: approved ? "accent" : "alert" });
    } catch (error) {
      notifications.show({ title: "Could not review walkthrough", message: error instanceof Error ? error.message : String(error), color: "alert" });
    }
  }

  async function completeDesignCard() {
    setSaving(true);
    try {
      await api.completeDesignCard(item!.id);
      await onChanged();
      notifications.show({ title: "Design contract completed", message: `${item!.item_key} moved directly from Plan to Done`, color: "accent" });
    } catch (error) {
      notifications.show({ title: "Design card is not ready", message: error instanceof Error ? error.message : String(error), color: "alert" });
    } finally { setSaving(false); }
  }

  async function makePrimary(asset: WorkItemAsset) {
    const [updated] = await api.setPrimaryWorkItemAsset(asset.id);
    if (updated) setAssets((current) => current.map((entry) => ({ ...entry, is_primary: entry.id === updated.id })));
    await onChanged();
  }

  async function removeVisual(asset: WorkItemAsset) {
    await api.deleteWorkItemAsset(asset.id);
    if (asset.source_url.startsWith("/uploads/")) {
      await api.deleteUploadedMedia(asset.source_url).catch(() => undefined);
    }
    setAssets((current) => current.filter((entry) => entry.id !== asset.id));
    if (activeVisual?.id === asset.id) setActiveVisual(null);
    await onChanged();
  }

  async function approveConcept(asset: WorkItemAsset) {
    try {
      await api.approveVisualConcept(item!.id, asset.id);
      const [nextAssets, nextContext] = await Promise.all([api.workItemAssets(item!.id), api.workItemContext(item!.id)]);
      setAssets(nextAssets); setWorkContext(nextContext); await onChanged();
      notifications.show({ title: "Visual concept approved", message: "The design concept artefact can now be completed.", color: "accent" });
    } catch (error) {
      notifications.show({ title: "Could not approve concept", message: error instanceof Error ? error.message : String(error), color: "alert" });
    }
  }

  async function approveScreen(asset: WorkItemAsset) {
    try {
      await api.approveScreenMockup(asset.id);
      const [nextAssets, nextContext] = await Promise.all([api.workItemAssets(item!.id), api.workItemContext(item!.id)]);
      setAssets(nextAssets); setWorkContext(nextContext); await onChanged();
      notifications.show({ title: "Screen mockup approved", message: asset.screen_name ?? item!.item_key, color: "accent" });
    } catch (error) {
      notifications.show({ title: "Could not approve mockup", message: error instanceof Error ? error.message : String(error), color: "alert" });
    }
  }

  return <Drawer
    opened={opened}
    onClose={onClose}
    position="right"
    size="min(520px, 100vw)"
    closeButtonProps={{ "aria-label": "Close work item" }}
    overlayProps={{ backgroundOpacity: 0.14 }}
    classNames={{ root: "record-drawer", header: "record-drawer-header", body: "record-drawer-body", content: "record-drawer-content" }}
    title={<div className="record-drawer-heading" tabIndex={-1} data-autofocus><div className="eyebrow">{item.item_key} · {stage?.title ?? item.kind}</div><h2>{item.title}</h2><div><span className={`state-dot ${item.execution_state ?? item.progress}`} />{item.execution_state?.replaceAll("_", " ") ?? item.progress.replaceAll("_", " ")}<i>·</i>{item.assignee ?? "Unassigned"}</div></div>}
  >
    <section className="record-block record-notes">
      <div className="record-block-title">Notes</div>
      <Textarea aria-label="Notes" autosize minRows={3} value={description} onChange={(event) => setDescription(event.currentTarget.value)} placeholder="Describe the intent and expected outcome." />
    </section>

    {item.kind === "story" && <section className="record-block">
      <div className="record-block-title">Tasks <span>{childTasks.filter((task) => task.progress === "completed").length} / {childTasks.length}</span></div>
      <div className="record-task-list">{childTasks.map((task) => <div className={task.progress === "completed" ? "record-task-completed" : undefined} key={task.id}><span className={task.progress === "completed" ? "done" : ""}>{task.progress === "completed" ? "✓" : ""}</span><div><strong>{task.title}</strong><small>{task.item_key} · {task.execution_state?.replaceAll("_", " ") ?? task.progress.replaceAll("_", " ")}</small></div></div>)}</div>
      <Group className="record-add-row" align="flex-end" gap="xs"><TextInput label="Add task" placeholder="Describe a concrete piece of work" value={newTaskTitle} onChange={(event) => setNewTaskTitle(event.currentTarget.value)} onKeyDown={(event) => { if (event.key === "Enter") void addTask(); }} /><Button loading={addingTask} disabled={!newTaskTitle.trim()} onClick={addTask}>Add</Button></Group>
    </section>}

    <section className="record-block">
      <div className="record-block-title">Exit criteria <label><span className="record-checkbox" /> Show on card</label></div>
      <div className="record-empty-action">+ Add</div>
    </section>

    <section className="record-block">
      <div className="record-block-title">Acceptance criteria <span>{item.acceptance_criteria.length}</span></div>
      <div className="record-criteria">{item.acceptance_criteria.length ? item.acceptance_criteria.map((criterion, index) => <div key={criterion.id ?? index}>
        <span className={criterion.status === "passed" ? "done" : ""}>{criterion.status === "passed" ? "✓" : ""}</span>
        <p><strong>{criterion.statement}</strong><small>{criterion.verification_method.replaceAll("_", " ")} · {criterion.verification_ref}<br />Expected: {criterion.expected_result}{criterion.revision ? ` · ${criterion.revision}` : ""}</small></p>
      </div>) : <p className="record-muted">No deterministic acceptance criteria recorded.</p>}</div>
      {canEditAcceptance && <details className="record-edit-details acceptance-editor">
        <summary>Define deterministic criteria</summary>
        <div className="record-edit-form">
          {acceptanceCriteria.map((criterion, index) => <div className="acceptance-builder-row" key={index}>
            <TextInput label="Pass condition" value={criterion.statement} onChange={(event) => setAcceptanceCriteria((current) => current.map((entry, entryIndex) => entryIndex === index ? { ...entry, statement: event.currentTarget.value } : entry))} required />
            <Select label="Verification method" data={acceptanceVerificationMethods} value={criterion.verificationMethod} onChange={(value) => setAcceptanceCriteria((current) => current.map((entry, entryIndex) => entryIndex === index ? { ...entry, verificationMethod: (value ?? "automated_test") as AcceptanceVerificationMethod } : entry))} />
            <TextInput label="Test, command, endpoint, query or baseline" value={criterion.verificationRef} onChange={(event) => setAcceptanceCriteria((current) => current.map((entry, entryIndex) => entryIndex === index ? { ...entry, verificationRef: event.currentTarget.value } : entry))} required />
            <Textarea label="Exact expected result" minRows={2} value={criterion.expectedResult} onChange={(event) => setAcceptanceCriteria((current) => current.map((entry, entryIndex) => entryIndex === index ? { ...entry, expectedResult: event.currentTarget.value } : entry))} required />
            {acceptanceCriteria.length > 1 && <Button className="acceptance-remove" size="compact-sm" onClick={() => setAcceptanceCriteria((current) => current.filter((_, entryIndex) => entryIndex !== index))}>Remove</Button>}
          </div>)}
          <Button size="compact-sm" onClick={() => setAcceptanceCriteria((current) => [...current, emptyAcceptanceCriterion()])}>Add criterion</Button>
        </div>
      </details>}
    </section>

    {item.kind === "story" && <section className="record-block">
      <div className="record-block-title">Invariants <span>{item.invariants.length}</span></div>
      {item.invariants.length ? <div className="record-criteria">{item.invariants.map((invariant, index) => <div key={index}><span>•</span><p><strong>{invariant}</strong></p></div>)}</div> : <p className="record-muted">No invariants recorded.</p>}
      {canEditAcceptance && <Textarea
        label="Define invariants"
        description="One implementation constraint per line. Invariants become immutable when Build begins."
        minRows={3}
        value={invariants}
        onChange={(event) => setInvariants(event.currentTarget.value)}
      />}
    </section>}

    {item.kind === "story" && <section className="record-block">
      <div className="record-block-title">Promotion acceptance <span>{workContext?.promotion.ready ? "Ready" : "Not ready"}</span></div>
      <p className="record-muted">What must be true to move from {workContext?.promotion.current_stage.title ?? stage?.title ?? "this stage"} to the next stage.</p>
      <div className="record-criteria">{workContext?.promotion.acceptance_criteria.map((criterion, index) => <div key={index}>
        <span className={criterion.satisfied ? "done" : ""}>{criterion.satisfied ? "✓" : ""}</span>
        <p><strong>{criterion.requirement}</strong><small>{criterion.policy ? `${criterion.policy}${criterion.blocking ? " · blocking" : ""}` : criterion.blocking === false ? "recommended" : "required"}{criterion.waiver_reason ? ` · Waived: ${criterion.waiver_reason}` : ""}{criterion.revision ? ` · Revision: ${criterion.revision}` : ""}</small></p>
      </div>) ?? <p className="record-muted">Loading promotion criteria…</p>}</div>
      {item.design_card_type && stage?.slug === "plan" && <div className="record-design-completion">
        <p className="record-muted">Design-only completion closes the approved contract without claiming source implementation, validation, merge, or regression evidence.</p>
        <div className="record-criteria">{designCompletionRequirements.map((criterion, index) => <div key={`design-${index}`}>
          <span className={criterion.satisfied ? "done" : ""}>{criterion.satisfied ? "✓" : ""}</span>
          <p><strong>{criterion.requirement}</strong><small>design contract · required</small></p>
        </div>)}</div>
        <Button loading={saving} disabled={!designCompletionRequirements.length || designCompletionRequirements.some((criterion) => !criterion.satisfied)} onClick={completeDesignCard}>Complete approved design contract</Button>
      </div>}
    </section>}

    <section className="record-block record-facts">
      <div className="record-block-title">Facts</div>
      <div className="record-fact-grid">
        <span>Type</span><strong>{item.kind}</strong>
        <span>Parent</span><strong>{parent ? `${parent.item_key} · ${parent.title}` : `Top-level ${item.kind}`}</strong>
        <span>Stage</span><strong>{stage?.title ?? "Unknown"}</strong>
        <span>Progress</span><strong>{item.progress.replaceAll("_", " ")}</strong>
        <span>Priority</span><strong>{priority}</strong>
        <span>Start</span><strong>{dateLabel(item.start_date)}</strong>
        <span>Due</span><strong>{dateLabel(item.due_date)}</strong>
      </div>
      <details className="record-edit-details">
        <summary>Edit work item</summary>
        <div className="record-edit-form">
          <TextInput label="Title" value={title} onChange={(event) => setTitle(event.currentTarget.value)} />
          {(item.kind === "story" || item.kind === "task") && <Select label={item.kind === "story" ? "Feature" : "Parent story"} searchable clearable={item.kind === "story"} value={parentId} onChange={setParentId} data={parentOptions.map((entry) => ({ value: entry.id, label: `${entry.item_key} · ${entry.title}` }))} />}
          <Group grow><Select label="Priority" value={priority} onChange={(value) => setPriority((value ?? "medium") as Priority)} data={["urgent", "high", "medium", "low"]} /><Select label="Execution" clearable value={execution} onChange={(value) => setExecution(value as ExecutionState)} data={["queued", "running", "waiting_for_human", "blocked", "failed", "complete", "cancelled"]} /></Group>
          <TextInput label="Assignee" value={assignee} onChange={(event) => setAssignee(event.currentTarget.value)} />
          {(item.kind === "story" || item.kind === "feature") && <Switch
            checked={visualEvidenceRequired || inheritsVisualRequirement}
            onChange={(event) => setVisualEvidenceRequired(event.currentTarget.checked)}
            disabled={!canEditVisualRequirement || inheritsVisualRequirement}
            label="Visual change"
            description={inheritsVisualRequirement
              ? "Inherited from the parent feature."
              : item.kind === "feature"
                ? "Child stories inherit the visual design and validation evidence gates."
                : "Require visual design and validation evidence only for this story."}
          />}
          {item.kind === "story" && <Switch
            checked={interactionEvidenceRequired}
            onChange={(event) => setInteractionEvidenceRequired(event.currentTarget.checked)}
            disabled={!canEditVisualRequirement}
            label="Interaction walkthrough required"
            description="Use when acceptance depends on click, drag, touch, keyboard, navigation, animation, or a multi-step UI flow. This also enables visual evidence."
          />}
          {item.kind === "story" && (visualEvidenceRequired || inheritsVisualRequirement) && <>
            <Select
              label="Design role"
              value={designCardType ?? "implementation"}
              onChange={(value) => setDesignCardType(value === "implementation" ? null : value as DesignCardType)}
              data={[
                { value: "implementation", label: "Visual implementation story" },
                { value: "visual_concept", label: "Visual concept design card" },
                { value: "screen_mockup", label: "Screen mockup design card" },
              ]}
            />
            {designCardType !== "visual_concept" && <Textarea
              label="Screens, states and viewport variants"
              description="One approved mockup target per line."
              minRows={3}
              value={screenNames}
              onChange={(event) => setScreenNames(event.currentTarget.value)}
            />}
          </>}
          {(execution === "blocked" || execution === "failed" || execution === "waiting_for_human") && <Textarea label="What is blocking this?" value={blockedReason} onChange={(event) => setBlockedReason(event.currentTarget.value)} />}
        </div>
      </details>
    </section>

    {(item.kind === "story" || item.kind === "feature") && <section className="record-block record-dependencies">
      <div className="record-block-title">Dependencies</div>
      <MultiSelect aria-label="Prerequisites" searchable clearable placeholder="No prerequisites" value={prerequisiteIds} onChange={setPrerequisiteIds} data={dependencyOptions.map((entry) => ({ value: entry.id, label: `${entry.item_key} · ${entry.title}` }))} />
      <div className={`record-readiness ${incompletePrerequisites.length ? "blocked" : "ready"}`}>
        {incompletePrerequisites.length ? <IconLock size={15} /> : <IconCheck size={15} />}
        <span>{incompletePrerequisites.length ? `${incompletePrerequisites.length} prerequisite${incompletePrerequisites.length === 1 ? "" : "s"} must be Done before an agent can start` : effectivePrerequisiteIds.length ? "All prerequisites are Done · this work item can start" : "No prerequisites · this work item can start immediately"}</span>
      </div>
    </section>}

    <section className="record-block">
      <div className="record-block-title">Delivery gate</div>
      <div className={`record-gate-summary ${deliveryGate === "Blocked" || deliveryGate === "Failed" ? "blocked" : ""}`}>
        <strong>{deliveryGate}</strong>
        <span>{mergedEvidence ? `Merged revision ${shortRevision(mergedEvidence.revision)}` : `${stageTransitions.length} governed stage transition${stageTransitions.length === 1 ? "" : "s"} recorded`}</span>
      </div>
      {stageTransitions.length > 0 && <div className="record-stage-history">{stageTransitions.map((event) => <div key={event.id}>
        <span className="done">✓</span>
        <p><strong>{String(event.details.from ?? "start").replaceAll("_", " ")} → {String(event.details.to ?? "unknown").replaceAll("_", " ")}</strong><small>{event.summary} · {timestampLabel(event.created_at)}</small></p>
      </div>)}</div>}
    </section>

    {item.kind === "story" && <section className="record-block record-visuals">
      <div className="record-block-title">Visual evidence <span>{assets.length}</span></div>
      {assets.length ? <div className="record-visual-grid">{assets.map((asset) => <article className={asset.is_primary ? "primary" : ""} key={asset.id}>
        <button className="record-visual-preview" onClick={() => setActiveVisual(asset)}>
          {asset.mime_type.startsWith("video/")
            ? <>{asset.thumbnail_url ? <img src={asset.thumbnail_url} alt="" loading="lazy" decoding="async" /> : <video src={asset.source_url} muted preload="none" />}<span className="record-video-badge"><IconVideo size={15} /> Play recording</span></>
            : <img src={asset.thumbnail_url ?? asset.source_url} alt={asset.caption || asset.filename || asset.asset_type.replaceAll("_", " ")} loading="lazy" decoding="async" />}
        </button>
        <div><strong>{asset.asset_type.replaceAll("_", " ")}</strong><span>{asset.screen_name ? `${asset.screen_name} · ` : ""}{asset.caption || asset.filename || "Attached visual"}</span>{asset.revision && <code>{shortRevision(asset.revision)}</code>}<small>{asset.asset_type === "validation_recording" ? `walkthrough ${asset.recording_review_status}` : asset.approval_status}</small></div>
        <Group gap={4} wrap="nowrap">
          {item.design_card_type === "visual_concept" && ["mockup", "wireframe"].includes(asset.asset_type) && asset.approval_status !== "approved" && <Button size="compact-xs" variant="subtle" onClick={() => void approveConcept(asset)}>Select</Button>}
          {asset.screen_name && ["mockup", "wireframe"].includes(asset.asset_type) && asset.approval_status !== "approved" && <Button size="compact-xs" variant="subtle" onClick={() => void approveScreen(asset)}>Approve</Button>}
          {asset.asset_type === "validation_recording" && asset.recording_review_status !== "approved" && <Button size="compact-xs" variant="subtle" onClick={() => void reviewRecording(asset, true)}>Approve</Button>}
          {asset.asset_type === "validation_recording" && asset.recording_review_status !== "rejected" && <Button size="compact-xs" variant="subtle" color="alert" onClick={() => void reviewRecording(asset, false)}>Reject</Button>}
          {asset.asset_type !== "validation_recording" && !asset.is_primary && <ActionIcon variant="subtle" aria-label="Show on board card" title="Show on board card" onClick={() => void makePrimary(asset)}><IconStar size={15} /></ActionIcon>}
          <ActionIcon variant="subtle" color="alert" aria-label="Remove visual" title="Remove visual" onClick={() => void removeVisual(asset)}><IconTrash size={15} /></ActionIcon>
        </Group>
      </article>)}</div> : <div className="record-visual-empty"><IconPhoto size={18} /><p><strong>No visuals attached</strong><span>References, mockups and screenshots stay with the story and are returned to agents.</span></p></div>}
      <details className="record-edit-details record-visual-add">
        <summary>Attach visual</summary>
        <div className="record-edit-form">
          <FileInput accept="image/*,video/*" value={visualFile} onChange={setVisualFile} label="Media" placeholder="Choose an image or validation recording" clearable />
          <Group grow align="flex-start"><Select label="Type" data={visualAssetTypes} value={visualAssetType} onChange={(value) => setVisualAssetType((value ?? "reference") as WorkItemAssetType)} /><TextInput label="Revision" value={visualRevision} onChange={(event) => setVisualRevision(event.currentTarget.value)} placeholder="Required for implementation proof" /></Group>
          {["mockup", "wireframe"].includes(visualAssetType) && item.design_card_type !== "visual_concept" && item.screen_names.length > 0 && <Select
            label="Screen, state and viewport"
            placeholder="Assign this mockup"
            data={item.screen_names}
            value={visualScreenName}
            onChange={setVisualScreenName}
            required
          />}
          <TextInput label="Caption" value={visualCaption} onChange={(event) => setVisualCaption(event.currentTarget.value)} placeholder="What this image demonstrates" />
          {visualAssetType === "validation_recording" && <Textarea
            label="Timestamped walkthrough"
            description="Continuous 1× capture with pointer/touch visible. Pause after every action. One line per step."
            placeholder={"2 | Click Start | The game board appears\n6 | Drag across connected letters | The selected path and provisional word remain visible"}
            minRows={4}
            value={recordingSteps}
            onChange={(event) => setRecordingSteps(event.currentTarget.value)}
          />}
          <Button loading={addingVisual} disabled={!visualFile} onClick={addVisual}>Attach visual</Button>
        </div>
      </details>
    </section>}

    <section className="record-block record-proof">
      <div className="record-block-title">Proof <span>{evidence.length}</span></div>
      {evidence.length ? <div className="record-evidence-list">{evidence.map((entry) => { const recordings = assets.filter((asset) => asset.evidence_id === entry.id && asset.asset_type === "validation_recording"); return <article key={entry.id}>
        <header><span>{entry.evidence_type.replaceAll("_", " ")}</span><strong className={entry.outcome === "failed" || entry.outcome === "rejected" ? "failed" : ""}>{entry.outcome}</strong></header>
        <p>{entry.summary}</p>
        {recordings.map((recording) => <div className="record-evidence-video" key={recording.id}><video src={recording.source_url} controls playsInline preload="none" poster={recording.thumbnail_url ?? undefined} /><span>{recording.caption || recording.filename || "Validation recording"}</span></div>)}
        <footer><span>{entry.actor_name} · {timestampLabel(entry.created_at)}</span>{entry.revision && <code>{shortRevision(entry.revision)}</code>}{entry.url && <a href={entry.url} target="_blank" rel="noreferrer">Open evidence ↗</a>}</footer>
      </article>; })}</div> : <p className="record-muted">No delivery evidence has been recorded.</p>}
    </section>

    <section className="record-block record-conversation">
      <div className="record-block-title">Activity and comments <span>{timeline.length}</span></div>
      <div className="record-comment-form">
        <TextInput size="md" aria-label="Add a comment" value={newComment} onChange={(event) => setNewComment(event.currentTarget.value)} onKeyDown={(event) => { if (event.key === "Enter") void addComment(); }} placeholder="Add a note or question" />
        <Button size="md" loading={addingComment} disabled={!newComment.trim()} onClick={addComment}>Add comment</Button>
      </div>
      {timeline.length ? <div className="record-timeline">{timeline.map((entry) => {
        if (entry.kind === "comment") return <article className="comment" key={`comment-${entry.id}`}><i /><div><header><strong>{entry.comment.actor_name}</strong><span>Comment · {timestampLabel(entry.createdAt)}</span></header><p>{entry.comment.body}</p></div></article>;
        if (entry.kind === "evidence") return <article className="evidence" key={`evidence-${entry.id}`}><i /><div><header><strong>{entry.evidence.evidence_type.replaceAll("_", " ")} · {entry.evidence.outcome}</strong><span>{entry.evidence.actor_name} · {timestampLabel(entry.createdAt)}</span></header><p>{entry.evidence.summary}</p></div></article>;
        const transition = entry.event.event_type === "work_item.moved";
        return <article className={transition ? "transition" : "event"} key={`event-${entry.id}`}><i /><div><header><strong>{transition ? `${String(entry.event.details.from ?? "start")} → ${String(entry.event.details.to ?? "unknown")}` : entry.event.summary}</strong><span>{entry.event.actor_name} · {timestampLabel(entry.createdAt)}</span></header>{transition && <p>{entry.event.summary}</p>}</div></article>;
      })}</div> : <p className="record-muted">No activity has been recorded.</p>}
    </section>

    <section className="record-block record-register"><div className="record-block-title">Project decisions, issues and risks</div><Link to={`/projects/${item.project_id}#project-record`}>Open project register <IconArrowRight size={16} stroke={1.5} /></Link></section>

    <div className="record-save-bar"><span>Updated {new Date(item.updated_at).toLocaleString()}</span><Button loading={saving} disabled={canEditAcceptance && !acceptanceValid} onClick={save}>Save changes</Button></div>
    <Modal opened={Boolean(activeVisual)} onClose={() => setActiveVisual(null)} size="min(1120px, 96vw)" centered overlayProps={{ backgroundOpacity: 0.72, blur: 2 }} title={activeVisual ? activeVisual.caption || activeVisual.asset_type.replaceAll("_", " ") : "Visual"} classNames={{ root: "visual-lightbox" }}>
      {activeVisual && <div className="visual-lightbox-body">{activeVisual.mime_type.startsWith("video/") ? <video src={activeVisual.source_url} controls autoPlay playsInline /> : <img src={activeVisual.source_url} alt={activeVisual.caption || activeVisual.filename || "Work item visual"} />}<footer><span>{activeVisual.asset_type.replaceAll("_", " ")} · {activeVisual.created_by}</span>{activeVisual.revision && <code>{activeVisual.revision}</code>}</footer></div>}
    </Modal>
  </Drawer>;
}
