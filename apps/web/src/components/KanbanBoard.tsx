import { DndContext, DragOverlay, PointerSensor, useDraggable, useDroppable, useSensor, useSensors, type DragEndEvent, type DragStartEvent } from "@dnd-kit/core";
import { CSS } from "@dnd-kit/utilities";
import { Accordion } from "@mantine/core";
import { useLayoutEffect, useMemo, useRef, useState } from "react";
import { IconAlertTriangle, IconCheck, IconClock, IconGripVertical, IconListCheck, IconLock, IconPhoto } from "@tabler/icons-react";
import { groupStagesIntoDeliveryPhases } from "../deliveryPhases";
import type { Stage, WorkItem, WorkItemAsset, WorkItemDependency } from "../types";

function stateLabel(item: WorkItem) {
  if (item.execution_state) return item.execution_state.replaceAll("_", " ");
  if (item.completed_at) return "complete";
  return item.progress.replaceAll("_", " ");
}

function WorkCard({ item, tasks = [], blockedBy = [], assets = [], visualChange = false, selected, onOpen, overlay = false }: { item: WorkItem; tasks?: WorkItem[]; blockedBy?: WorkItem[]; assets?: WorkItemAsset[]; visualChange?: boolean; selected?: boolean; onOpen?: () => void; overlay?: boolean }) {
  const drag = useDraggable({ id: item.id, disabled: overlay, data: { type: "item", item } });
  const style = { transform: CSS.Translate.toString(drag.transform), opacity: drag.isDragging ? 0.35 : 1 };
  const blocked = item.execution_state === "blocked" || item.execution_state === "failed" || item.execution_state === "waiting_for_human";
  const checked = item.checklist.filter((entry) => entry.checked).length;
  const cardVisuals = assets.filter((asset) => asset.mime_type.startsWith("image/"));
  const primaryVisual = cardVisuals.find((asset) => asset.is_primary) ?? cardVisuals[0];
  return (
    <article ref={drag.setNodeRef} data-work-item-id={item.id} style={style} className={`work-card ${item.execution_state === "running" ? "running" : ""} ${selected ? "selected" : ""} ${overlay ? "overlay" : ""}`} onClick={onOpen}>
      <button className="drag-handle" aria-label={`Move ${item.item_key}`} {...drag.listeners} {...drag.attributes} onClick={(event) => event.stopPropagation()}><IconGripVertical size={14} /></button>
      <div className="card-key">{item.item_key} · {item.kind}</div>
      <h4>{item.title}</h4>
      {item.design_card_type && <div className="card-design-role">{item.design_card_type === "visual_concept" ? "Visual concept design" : "Screen mockups"}</div>}
      {primaryVisual && <div className="card-visual"><img src={primaryVisual.thumbnail_url ?? primaryVisual.source_url} alt={primaryVisual.caption || `${item.title} visual`} loading="lazy" decoding="async" /><span>{primaryVisual.asset_type.replaceAll("_", " ")}</span></div>}
      {!primaryVisual && visualChange && <div className="card-visual-required"><IconPhoto size={13} />Visual change</div>}
      {blocked && <div className="blocked-row"><IconAlertTriangle size={13} />{item.blocked_reason || stateLabel(item)}</div>}
      {item.checklist.length > 0 && <div className="checklist-preview"><span>{checked}/{item.checklist.length}</span><div><i style={{ width: `${(checked / item.checklist.length) * 100}%` }} /></div></div>}
      {(tasks.length > 0 || blockedBy.length > 0) && <div className="story-signals">{tasks.length > 0 && <span><IconListCheck size={13} />{tasks.filter((task) => task.completed_at).length}/{tasks.length} tasks</span>}{blockedBy.length > 0 && <span className="dependency-block"><IconLock size={12} />{blockedBy.length} prerequisite{blockedBy.length === 1 ? "" : "s"}</span>}</div>}
      <div className="card-foot"><span className={`state-dot ${item.execution_state ?? item.progress}`} /> <span>{stateLabel(item)}</span><span className="push">{(item.assignee ?? item.owner)?.replace(" Agent", " AGT") ?? "Unowned"}</span></div>
      <div className="card-meta"><span>{item.priority}</span><span>{item.estimate_points} pt</span>{item.due_date && <span><IconClock size={11} /> {new Date(`${item.due_date}T00:00:00`).toLocaleDateString(undefined, { month: "short", day: "numeric" })}</span>}</div>
    </article>
  );
}

function FeatureCard({ item, stories, onOpen }: { item: WorkItem; stories: WorkItem[]; onOpen: () => void }) {
  const storyIsDone = (story: WorkItem) => Boolean(story.completed_at) || story.progress === "completed";
  const done = stories.filter(storyIsDone).length;
  const active = stories.filter((story) => story.execution_state === "running").length;
  const blocked = stories.filter((story) => ["blocked", "failed", "waiting_for_human"].includes(story.execution_state ?? "")).length;
  return <button className="feature-card" data-work-item-id={item.id} onClick={onOpen}>
    <span className="card-key">{item.item_key} · feature</span>
    <strong>{item.title}</strong>
    {item.visual_evidence_required && <span className="card-visual-required"><IconPhoto size={13} />Visual change</span>}
    <span>{done}/{stories.length} done · {active} active{blocked ? ` · ${blocked} blocked` : ""}</span>
    {stories.length > 0 && <span className="feature-story-list">{stories.map((story) => {
      const complete = storyIsDone(story);
      return <span className={complete ? "complete" : ""} key={story.id}>
        <i>{complete && <IconCheck size={9} stroke={2} />}</i>
        <b>{story.item_key}</b>
        <span>{story.title}</span>
      </span>;
    })}</span>}
    <i className="feature-progress"><b style={{ width: `${stories.length ? (done / stories.length) * 100 : 0}%` }} /></i>
  </button>;
}

function StageSection({ stage, items, features, allItems, dependencies, assets, onOpen }: { stage: Stage; items: WorkItem[]; features: WorkItem[]; allItems: WorkItem[]; dependencies: WorkItemDependency[]; assets: WorkItemAsset[]; onOpen: (item: WorkItem) => void }) {
  const drop = useDroppable({ id: stage.id, data: { type: "stage", stage } });
  const overLimit = stage.wip_limit !== null && items.length > stage.wip_limit;
  const openGroups = [features.length > 0 ? "features" : "", items.length > 0 ? "stories" : ""].filter(Boolean);
  return (
    <Accordion.Item ref={drop.setNodeRef} value={stage.id} className={`kanban-stage ${drop.isOver ? "drop-target" : ""}`}>
      <Accordion.Control className="stage-control" aria-label={`${stage.title} state, ${items.length + features.length} work items`}>
        <div className="stage-summary"><div><span>{stage.title}</span><p>{stage.responsible_actor}</p></div><div className={overLimit ? "count over" : "count"}>{items.length + features.length}{stage.wip_limit ? ` / ${stage.wip_limit}` : ""}</div></div>
      </Accordion.Control>
      <Accordion.Panel className="stage-panel">
        {openGroups.length > 0 ? <Accordion multiple defaultValue={openGroups} className="work-type-accordion">
          {features.length > 0 && <Accordion.Item value="features">
            <Accordion.Control className="work-type-control"><span>Features</span><i>{features.length}</i></Accordion.Control>
            <Accordion.Panel><div className="feature-band">{features.map((feature) => <FeatureCard key={feature.id} item={feature} stories={allItems.filter((item) => item.kind === "story" && item.parent_id === feature.id)} onOpen={() => onOpen(feature)} />)}</div></Accordion.Panel>
          </Accordion.Item>}
          {items.length > 0 && <Accordion.Item value="stories">
            <Accordion.Control className="work-type-control"><span>Stories</span><i>{items.length}</i></Accordion.Control>
            <Accordion.Panel><div className="lane-cards">{items.map((item) => {
              const blockedBy = dependencies.filter((dependency) => dependency.work_item_id === item.id || (item.parent_id !== null && dependency.work_item_id === item.parent_id)).map((dependency) => allItems.find((entry) => entry.id === dependency.depends_on_work_item_id)).filter((entry): entry is WorkItem => entry !== undefined).filter((entry) => !entry.completed_at && entry.progress !== "completed");
              const parentFeature = item.parent_id ? allItems.find((entry) => entry.id === item.parent_id && entry.kind === "feature") : undefined;
              return <WorkCard key={item.id} item={item} tasks={allItems.filter((entry) => entry.kind === "task" && entry.parent_id === item.id)} blockedBy={blockedBy} assets={assets.filter((asset) => asset.work_item_id === item.id)} visualChange={item.visual_evidence_required || Boolean(parentFeature?.visual_evidence_required)} onOpen={() => onOpen(item)} />;
            })}</div></Accordion.Panel>
          </Accordion.Item>}
        </Accordion> : <div className="lane-empty">Drop work here</div>}
      </Accordion.Panel>
    </Accordion.Item>
  );
}

function PhaseLane({ title, phaseStages, stories, features, allItems, dependencies, assets, onOpen }: { title: string; phaseStages: Stage[]; stories: WorkItem[]; features: WorkItem[]; allItems: WorkItem[]; dependencies: WorkItemDependency[]; assets: WorkItemAsset[]; onOpen: (item: WorkItem) => void }) {
  const itemCount = phaseStages.reduce((total, stage) => total + stories.filter((item) => item.stage_id === stage.id).length, 0);
  const featureCount = phaseStages.reduce((total, stage) => total + features.filter((item) => item.stage_id === stage.id).length, 0);
  const stageSummary = phaseStages.map((stage) => stage.slug === "post_merge" ? "Post-merge" : stage.title).join(" · ");
  return <section className="kanban-phase">
    <header className="phase-header">
      <div><span>{title}</span>{phaseStages.length > 1 && <p>{stageSummary}</p>}</div>
      <div className="count">{itemCount + featureCount}</div>
    </header>
    <Accordion multiple defaultValue={phaseStages.map((stage) => stage.id)} className="phase-stages" aria-label={`${title} lane states`}>
      {phaseStages.map((stage) => <StageSection
        key={stage.id}
        stage={stage}
        items={stories.filter((item) => item.stage_id === stage.id)}
        features={features.filter((feature) => feature.stage_id === stage.id)}
        allItems={allItems}
        dependencies={dependencies}
        assets={assets}
        onOpen={onOpen}
      />)}
    </Accordion>
  </section>;
}

export function KanbanBoard({ stages, items, dependencies, assets, onMove, onOpen }: { stages: Stage[]; items: WorkItem[]; dependencies: WorkItemDependency[]; assets: WorkItemAsset[]; onMove: (itemId: string, stage: Stage) => Promise<void>; onOpen: (item: WorkItem) => void }) {
  const [active, setActive] = useState<WorkItem | null>(null);
  const gridRef = useRef<HTMLDivElement>(null);
  const previousPositions = useRef(new Map<string, DOMRect>());
  const previousStages = useRef(new Map<string, string>());
  const sensors = useSensors(useSensor(PointerSensor, { activationConstraint: { distance: 6 } }));
  const stories = useMemo(() => items.filter((item) => item.kind === "story"), [items]);
  const features = useMemo(() => items.filter((item) => item.kind === "feature"), [items]);
  const phases = useMemo(() => groupStagesIntoDeliveryPhases(stages), [stages]);
  useLayoutEffect(() => {
    const cards = gridRef.current?.querySelectorAll<HTMLElement>("[data-work-item-id]") ?? [];
    const nextPositions = new Map<string, DOMRect>();
    const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

    cards.forEach((card) => {
      const itemId = card.dataset.workItemId;
      if (!itemId) return;
      const next = card.getBoundingClientRect();
      const previous = previousPositions.current.get(itemId);
      const item = items.find((entry) => entry.id === itemId);
      const previousStage = previousStages.current.get(itemId);
      nextPositions.set(itemId, next);
      if (!previous || !item || !previousStage || previousStage === item.stage_id || reduceMotion) return;

      const deltaX = previous.left - next.left;
      const deltaY = previous.top - next.top;
      if (Math.abs(deltaX) < 1 && Math.abs(deltaY) < 1) return;

      card.animate(
        [
          { transform: `translate(${deltaX}px, ${deltaY}px)` },
          { transform: "translate(0, 0)" },
        ],
        { duration: 420, easing: "cubic-bezier(0.4, 0, 0.2, 1)" },
      );
    });

    previousPositions.current = nextPositions;
    previousStages.current = new Map(items.map((item) => [item.id, item.stage_id]));
  }, [items]);
  function start(event: DragStartEvent) { setActive(items.find((item) => item.id === event.active.id) ?? null); }
  async function end(event: DragEndEvent) {
    const item = items.find((entry) => entry.id === event.active.id);
    const stage = stages.find((entry) => entry.id === event.over?.id);
    setActive(null);
    if (item && stage && item.stage_id !== stage.id) await onMove(item.id, stage);
  }
  return (
    <DndContext sensors={sensors} onDragStart={start} onDragEnd={end} onDragCancel={() => setActive(null)}>
      <div className="kanban-scroll"><div ref={gridRef} className="kanban-grid">{phases.map((phase) => <PhaseLane key={phase.key} title={phase.title} phaseStages={phase.stages} stories={stories} features={features} allItems={items} dependencies={dependencies} assets={assets} onOpen={onOpen} />)}</div></div>
      <DragOverlay>{active ? <WorkCard item={active} tasks={items.filter((entry) => entry.kind === "task" && entry.parent_id === active.id)} assets={assets.filter((asset) => asset.work_item_id === active.id)} overlay /> : null}</DragOverlay>
    </DndContext>
  );
}
