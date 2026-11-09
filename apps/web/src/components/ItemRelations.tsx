import { IconArrowRight } from "@tabler/icons-react";
import type { Stage, WorkItem, WorkItemRegisterEntry } from "../types";

export function FeatureStories({ stories, stages, onSelect }: { stories: WorkItem[]; stages: Stage[]; onSelect?: (item: WorkItem) => void }) {
  const completedCount = stories.filter((story) => story.completed_at || story.progress === "completed").length;
  return <section className="record-block">
    <div className="record-block-title">Stories <span>{completedCount} / {stories.length}</span></div>
    {stories.length > 0 ? <div className="record-story-list">{stories.map((story) => {
      const completed = Boolean(story.completed_at) || story.progress === "completed";
      const storyStage = stages.find((entry) => entry.id === story.stage_id);
      return <button className={completed ? "record-story-completed" : undefined} key={story.id} type="button" onClick={() => onSelect?.(story)} disabled={!onSelect}>
        <span className={completed ? "done" : ""}>{completed ? "✓" : ""}</span>
        <div><strong>{story.title}</strong><small>{story.item_key} · {storyStage?.title ?? story.progress.replaceAll("_", " ")}</small></div>
        {onSelect && <IconArrowRight size={15} stroke={1.5} />}
      </button>;
    })}</div> : <p className="record-muted">No stories are linked to this feature.</p>}
  </section>;
}

const registerGroups = [
  ["decision", "Decisions"],
  ["issue", "Issues"],
  ["risk", "Risks"],
] as const;

export function RelatedRegisterEntries({ entries }: { entries: WorkItemRegisterEntry[] }) {
  return <section className="record-block record-register">
    <div className="record-block-title">Project decisions, issues and risks</div>
    <div className="record-register-groups">{registerGroups.map(([entryType, label]) => {
      const relatedEntries = entries.filter((entry) => entry.entry_type === entryType);
      return <div className="record-register-group" key={entryType}>
        <h3>{label}<span>{relatedEntries.length}</span></h3>
        {relatedEntries.length ? relatedEntries.map((entry) => <article key={entry.id}>
          <strong>{entry.title}</strong>
          {entry.description && <p>{entry.description}</p>}
          <small>{entry.status}{entry.owner ? ` · ${entry.owner}` : ""}</small>
        </article>) : <p className="record-register-empty">None registered</p>}
      </div>;
    })}</div>
  </section>;
}
