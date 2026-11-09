import { Button, Group, Modal, Select, Stack, Switch, TextInput, Textarea } from "@mantine/core";
import { useEffect, useState } from "react";
import { notifications } from "@mantine/notifications";
import { api } from "../api";
import type { AcceptanceCriterionInput, AcceptanceVerificationMethod, DesignCardType, Priority, WorkItem, WorkKind } from "../types";

const verificationMethods: Array<{ value: AcceptanceVerificationMethod; label: string }> = [
  { value: "automated_test", label: "Automated test" },
  { value: "command", label: "Command" },
  { value: "http_assertion", label: "HTTP assertion" },
  { value: "database_assertion", label: "Database assertion" },
  { value: "visual_baseline", label: "Visual baseline" },
];

function emptyCriterion(): AcceptanceCriterionInput {
  return { statement: "", verificationMethod: "automated_test", verificationRef: "", expectedResult: "" };
}

export function CreateItemModal({ projectId, items, opened, onClose, onCreated }: { projectId: string; items: WorkItem[]; opened: boolean; onClose: () => void; onCreated: () => void }) {
  const [title, setTitle] = useState("");
  const [description, setDescription] = useState("");
  const [kind, setKind] = useState<WorkKind>("story");
  const [priority, setPriority] = useState<Priority>("medium");
  const [assignee, setAssignee] = useState("");
  const [parentId, setParentId] = useState<string | null>(null);
  const [criteria, setCriteria] = useState<AcceptanceCriterionInput[]>([emptyCriterion()]);
  const [invariants, setInvariants] = useState("");
  const [visualEvidenceRequired, setVisualEvidenceRequired] = useState(false);
  const [designCardType, setDesignCardType] = useState<DesignCardType>(null);
  const [screenNames, setScreenNames] = useState("");
  const [saving, setSaving] = useState(false);
  const normalizedScreens = screenNames.split("\n").map((entry) => entry.trim()).filter(Boolean);
  const designScopeValid = kind !== "story" || !visualEvidenceRequired || designCardType === "visual_concept" || normalizedScreens.length > 0;
  const criteriaValid = kind !== "story" || criteria.every((criterion) =>
    criterion.statement.trim() && criterion.verificationRef.trim() && criterion.expectedResult.trim());
  function updateCriterion(index: number, patch: Partial<AcceptanceCriterionInput>) {
    setCriteria((current) => current.map((criterion, criterionIndex) =>
      criterionIndex === index ? { ...criterion, ...patch } : criterion));
  }
  async function create() {
    setSaving(true);
    try {
      await api.createItem({
        projectId, title: title.trim(), description: description.trim(), kind, priority,
        assignee, parentId: parentId ?? undefined,
        acceptanceCriteria: kind === "story" ? criteria.map((criterion) => ({
          ...criterion,
          statement: criterion.statement.trim(),
          verificationRef: criterion.verificationRef.trim(),
          expectedResult: criterion.expectedResult.trim(),
        })) : [],
        invariants: kind === "story" ? invariants.split("\n").map((entry) => entry.trim()).filter(Boolean) : [],
        visualEvidenceRequired: (kind === "story" || kind === "feature") && visualEvidenceRequired,
        designCardType: kind === "story" && visualEvidenceRequired ? designCardType : null,
        screenNames: kind === "story" && visualEvidenceRequired ? normalizedScreens : [],
      });
      notifications.show({ title: "Backlog item created", message: title, color: "accent" });
      setTitle(""); setDescription(""); setCriteria([emptyCriterion()]); setInvariants(""); setVisualEvidenceRequired(false); setDesignCardType(null); setScreenNames(""); onCreated(); onClose();
    } catch (error) {
      notifications.show({ title: "Could not create item", message: error instanceof Error ? error.message : String(error), color: "alert" });
    } finally { setSaving(false); }
  }
  useEffect(() => { setParentId(null); }, [kind]);
  const parentKind = kind === "task" ? "story" : "feature";
  const parents = items.filter((item) => item.kind === parentKind).map((item) => ({ value: item.id, label: `${item.item_key} · ${item.title}` }));
  return (
    <Modal opened={opened} onClose={onClose} title={<span className="modal-title">Add to backlog</span>} size="lg">
      <Stack gap="md">
        <TextInput label="Title" value={title} onChange={(e) => setTitle(e.currentTarget.value)} autoFocus />
        <Group grow><Select label="Type" value={kind} onChange={(v) => setKind((v ?? "story") as WorkKind)} data={["feature", "story", "task"]} /><Select label="Priority" value={priority} onChange={(v) => setPriority((v ?? "medium") as Priority)} data={["urgent", "high", "medium", "low"]} /></Group>
        {kind !== "feature" && <Select label={kind === "task" ? "Parent story" : "Parent feature"} required={kind === "task"} clearable={kind !== "task"} searchable value={parentId} onChange={setParentId} data={parents} />}
        <Textarea label="Description" minRows={3} value={description} onChange={(e) => setDescription(e.currentTarget.value)} />
        {kind === "story" && <div className="acceptance-builder">
          <div className="acceptance-builder-heading">
            <div><strong>Acceptance criteria</strong><span>Every criterion must have an exact, repeatable verification.</span></div>
            <Button size="compact-sm" onClick={() => setCriteria((current) => [...current, emptyCriterion()])}>Add criterion</Button>
          </div>
          {criteria.map((criterion, index) => <div className="acceptance-builder-row" key={index}>
            <TextInput label="Pass condition" placeholder="What observable condition must be true?" value={criterion.statement} onChange={(event) => updateCriterion(index, { statement: event.currentTarget.value })} required />
            <Group grow align="flex-start">
              <Select label="Verification method" data={verificationMethods} value={criterion.verificationMethod} onChange={(value) => updateCriterion(index, { verificationMethod: (value ?? "automated_test") as AcceptanceVerificationMethod })} />
              <TextInput label="Test, command, endpoint, query or baseline" value={criterion.verificationRef} onChange={(event) => updateCriterion(index, { verificationRef: event.currentTarget.value })} required />
            </Group>
            <Textarea label="Exact expected result" minRows={2} value={criterion.expectedResult} onChange={(event) => updateCriterion(index, { expectedResult: event.currentTarget.value })} required />
            {criteria.length > 1 && <Button className="acceptance-remove" size="compact-sm" onClick={() => setCriteria((current) => current.filter((_, criterionIndex) => criterionIndex !== index))}>Remove</Button>}
          </div>)}
        </div>}
        {kind === "story" && <Textarea
          label="Invariants"
          description="Constraints the implementation must preserve. Enter one invariant per line."
          minRows={3}
          value={invariants}
          onChange={(event) => setInvariants(event.currentTarget.value)}
          placeholder="Existing API contracts remain backward compatible"
        />}
        {(kind === "story" || kind === "feature") && <Switch
          checked={visualEvidenceRequired}
          onChange={(event) => setVisualEvidenceRequired(event.currentTarget.checked)}
          label="Visual change"
          description={kind === "feature"
            ? "Child stories inherit the visual design and validation evidence gates."
            : "Require visual design and validation evidence only for this story."}
        />}
        {kind === "story" && visualEvidenceRequired && <>
          <Select
            label="Design role"
            description="Concept cards present alternatives; screen mockup cards supply approved references shared by implementation stories."
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
            description="One required mockup target per line, for example: Results · empty · mobile."
            value={screenNames}
            onChange={(event) => setScreenNames(event.currentTarget.value)}
            minRows={3}
            placeholder={"Game · default · desktop\nGame · active drag · mobile\nResults · multiplayer · mobile"}
            required
          />}
        </>}
        <TextInput label="Assignee" value={assignee} onChange={(e) => setAssignee(e.currentTarget.value)} placeholder="Person or agent" />
        <Group justify="flex-end"><Button onClick={onClose}>Cancel</Button><Button variant="filled" color="accent" loading={saving} disabled={!title.trim() || (kind === "task" && !parentId) || !criteriaValid || !designScopeValid} onClick={create}>Add item</Button></Group>
      </Stack>
    </Modal>
  );
}
