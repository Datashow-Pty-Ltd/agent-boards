import { Button, NumberInput, Textarea, TextInput } from "@mantine/core";
import { notifications } from "@mantine/notifications";
import { IconLock, IconPlayerPlay } from "@tabler/icons-react";
import { useEffect, useState } from "react";
import { useParams } from "react-router";
import { api } from "../api";
import type { Board, Stage } from "../types";

interface StageDraft {
  bucketTitle: string;
  purpose: string;
  responsibleActor: string;
  wipLimit: number | null;
  exitCriteria: string;
}

function draftFor(stage: Stage): StageDraft {
  return {
    bucketTitle: stage.bucket_title,
    purpose: stage.purpose,
    responsibleActor: stage.responsible_actor,
    wipLimit: stage.wip_limit,
    exitCriteria: stage.exit_criteria.join("\n"),
  };
}

export function ProjectSettingsPage() {
  const { projectId = "" } = useParams();
  const [board, setBoard] = useState<Board | null>(null);
  const [stages, setStages] = useState<Stage[]>([]);
  const [drafts, setDrafts] = useState<Record<string, StageDraft>>({});
  const [saving, setSaving] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let disposed = false;
    void api.boardSettings(projectId).then((data) => {
      if (disposed) return;
      setBoard(data.board);
      setStages(data.stages);
      setDrafts(Object.fromEntries(data.stages.map((stage) => [stage.id, draftFor(stage)])));
    }).catch((reason) => { if (!disposed) setError(reason instanceof Error ? reason.message : String(reason)); });
    return () => { disposed = true; };
  }, [projectId]);

  function updateDraft(stageId: string, values: Partial<StageDraft>) {
    setDrafts((current) => ({ ...current, [stageId]: { ...current[stageId], ...values } }));
  }

  async function save(stage: Stage) {
    const draft = drafts[stage.id];
    if (!draft) return;
    setSaving(stage.id);
    try {
      const updated = await api.updateBoardStageSettings(stage.id, {
        bucketTitle: draft.bucketTitle,
        purpose: draft.purpose,
        responsibleActor: draft.responsibleActor,
        wipLimit: draft.wipLimit,
        exitCriteria: draft.exitCriteria.split("\n").map((criterion) => criterion.trim()).filter(Boolean),
      });
      if (updated) {
        setStages((current) => current.map((entry) => entry.id === updated.id ? updated : entry));
        setDrafts((current) => ({ ...current, [updated.id]: draftFor(updated) }));
      }
      notifications.show({ title: "Stage settings saved", message: `${stage.title} now uses the updated bucket and exit criteria.`, color: "accent" });
    } catch (reason) {
      notifications.show({ title: "Could not save stage", message: reason instanceof Error ? reason.message : String(reason), color: "alert" });
    } finally {
      setSaving(null);
    }
  }

  if (error) return <div className="page-state"><h2>Settings unavailable</h2><p>{error}</p></div>;
  if (!board) return <div className="page-state" role="status">Loading project settings</div>;

  return <div className="settings-page ds-page">
    <header className="settings-head">
      <div><span className="eyebrow">Project settings</span><h1>Workflow configuration</h1><p>Group governed stages into visible board buckets and define the criteria required to leave each stage.</p></div>
      <Button leftSection={<IconPlayerPlay size={14} />} onClick={() => window.dispatchEvent(new Event("agent-boards:show-tour"))}>Replay overview</Button>
    </header>

    <aside className="settings-safety-note"><IconLock size={16} /><div><strong>Governed structure remains locked</strong><span>Stage order, identifiers and allowed transitions cannot be changed here. Database gates continue to enforce the delivery path.</span></div></aside>

    <div className="settings-stage-list">
      {stages.map((stage) => {
        const draft = drafts[stage.id];
        if (!draft) return null;
        return <section className="settings-stage" key={stage.id}>
          <header><div><span>{String(stage.position + 1).padStart(2, "0")} · {stage.slug.replaceAll("_", " ")}</span><h2>{stage.title}</h2></div><span className="settings-transition">Next: {stage.allowed_transitions.length ? stage.allowed_transitions.join(" · ") : "Terminal"}</span></header>
          <div className="settings-stage-form">
            <TextInput label="Board bucket" description="Adjacent stages with the same bucket are shown in one board lane." value={draft.bucketTitle} onChange={(event) => updateDraft(stage.id, { bucketTitle: event.currentTarget.value })} />
            <NumberInput label="WIP limit" description="Leave empty for no limit." min={1} max={100} value={draft.wipLimit ?? ""} onChange={(value) => updateDraft(stage.id, { wipLimit: typeof value === "number" ? value : null })} />
            <TextInput label="Responsible actor" value={draft.responsibleActor} onChange={(event) => updateDraft(stage.id, { responsibleActor: event.currentTarget.value })} />
            <Textarea className="settings-purpose" label="Purpose" autosize minRows={2} maxRows={5} value={draft.purpose} onChange={(event) => updateDraft(stage.id, { purpose: event.currentTarget.value })} />
            <Textarea className="settings-exit-criteria" label="Exit criteria" description="One deterministic requirement per line." autosize minRows={3} maxRows={10} value={draft.exitCriteria} onChange={(event) => updateDraft(stage.id, { exitCriteria: event.currentTarget.value })} />
          </div>
          <footer><Button loading={saving === stage.id} onClick={() => void save(stage)}>Save {stage.title}</Button></footer>
        </section>;
      })}
    </div>
  </div>;
}
