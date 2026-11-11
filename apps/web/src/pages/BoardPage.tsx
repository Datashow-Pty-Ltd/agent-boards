import { ActionIcon, Button } from "@mantine/core";
import { useDisclosure } from "@mantine/hooks";
import { notifications } from "@mantine/notifications";
import { IconArrowsMaximize, IconArrowsMinimize } from "@tabler/icons-react";
import { useCallback, useEffect, useRef, useState } from "react";
import { useParams, useSearchParams } from "react-router";
import { api } from "../api";
import { CreateItemModal } from "../components/CreateItemModal";
import { ItemDrawer } from "../components/ItemDrawer";
import { KanbanBoard } from "../components/KanbanBoard";
import { BoardSkeleton } from "../components/LoadingSkeletons";
import type { ActivityEvent, BoardData, Stage, WorkItem } from "../types";

const CARD_TRANSITION_MS = 460;

type BoardChangeEvent = Pick<ActivityEvent, "work_item_id" | "event_type" | "details">;

export function BoardPage() {
  const { projectId = "" } = useParams();
  const [searchParams] = useSearchParams();
  const requestedItemId = searchParams.get("item");
  const [data, setData] = useState<BoardData | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [selected, setSelected] = useState<WorkItem | null>(null);
  const [expanded, setExpanded] = useState(false);
  const [creating, createControls] = useDisclosure(false);
  const loadVersion = useRef(0);
  const movementQueues = useRef(new Map<string, Promise<void>>());
  const movementVersions = useRef(new Map<string, number>());
  const load = useCallback(async () => {
    const version = loadVersion.current + 1;
    loadVersion.current = version;
    try {
      const core = await api.boardCore(projectId);
      if (loadVersion.current !== version) return;
      setData(core);
      setSelected((current) => requestedItemId ? core.items.find((item) => item.id === requestedItemId) ?? null : current ? core.items.find((item) => item.id === current.id) ?? null : null);
      setError(null);
      void Promise.all([api.boardDependencies(core.items), api.boardAssets(projectId)]).then(([dependencies, assets]) => {
        if (loadVersion.current !== version) return;
        setData((current) => current ? { ...current, dependencies, assets } : current);
      }).catch(() => undefined);
    } catch (e) {
      if (loadVersion.current !== version) return;
      setError(e instanceof Error ? e.message : String(e));
    }
  }, [projectId, requestedItemId]);
  useEffect(() => { void load(); }, [load]);
  useEffect(() => {
    if (!projectId) return;
    let disposed = false;
    const movementQueueMap = movementQueues.current;
    const movementVersionMap = movementVersions.current;
    const source = new EventSource(`/mcp?projectId=${encodeURIComponent(projectId)}`);
    const reconcileItem = async (workItemId: string, version: number) => {
      const changedItem = await api.workItem(workItemId);
      if (disposed || movementVersionMap.get(workItemId) !== version) return;
      setData((current) => {
        if (!current) return current;
        return {
          ...current,
          items: changedItem
            ? current.items.some((item) => item.id === changedItem.id)
              ? current.items.map((item) => item.id === changedItem.id ? changedItem : item)
              : [...current.items, changedItem]
            : current.items.filter((item) => item.id !== workItemId),
        };
      });
      if (changedItem) setSelected((current) => current?.id === changedItem.id ? changedItem : current);
    };
    const enqueueMovement = (event: BoardChangeEvent) => {
      const workItemId = event.work_item_id;
      const targetSlug = typeof event.details?.to === "string" ? event.details.to : "";
      if (!workItemId || !targetSlug) return;
      const version = (movementVersionMap.get(workItemId) ?? 0) + 1;
      movementVersionMap.set(workItemId, version);
      const previous = movementQueueMap.get(workItemId) ?? Promise.resolve();
      const queued = previous.catch(() => undefined).then(async () => {
        if (disposed) return;
        setData((current) => {
          if (!current) return current;
          const targetStage = current.stages.find((stage) => stage.slug === targetSlug);
          if (!targetStage) return current;
          return {
            ...current,
            items: current.items.map((item) => item.id === workItemId ? {
              ...item,
              stage_id: targetStage.id,
              progress: targetSlug === "done" ? "completed" : targetSlug === "backlog" ? "not_started" : "in_progress",
              execution_state: targetSlug === "done" ? "complete" : item.execution_state,
            } : item),
          };
        });
        await new Promise((resolve) => window.setTimeout(resolve, CARD_TRANSITION_MS));
      }).then(async () => {
        if (disposed || movementVersionMap.get(workItemId) !== version) return;
        await reconcileItem(workItemId, version);
        if (movementQueueMap.get(workItemId) === queued) movementQueueMap.delete(workItemId);
      }).catch(() => {
        if (movementQueueMap.get(workItemId) === queued) movementQueueMap.delete(workItemId);
      });
      movementQueueMap.set(workItemId, queued);
    };
    const applyChange = (message: Event) => {
      let event: BoardChangeEvent;
      try {
        event = JSON.parse((message as MessageEvent<string>).data) as typeof event;
      } catch {
        return;
      }
      if (!event.work_item_id) return;
      if (event.event_type === "work_item.moved" && typeof event.details?.to === "string") {
        enqueueMovement(event);
        return;
      }
      void Promise.all([
        api.workItem(event.work_item_id),
        event.event_type?.includes("visual_asset") || event.event_type === "work_item.validation_recording_attached" ? api.workItemAssets(event.work_item_id) : Promise.resolve(null),
      ]).then(([changedItem, changedAssets]) => {
        if (disposed) return;
        setData((current) => {
          if (!current) return current;
          const items = changedItem
            ? current.items.some((item) => item.id === changedItem.id)
              ? current.items.map((item) => item.id === changedItem.id ? { ...changedItem, stage_id: item.stage_id } : item)
              : [...current.items, changedItem]
            : current.items.filter((item) => item.id !== event.work_item_id);
          const assets = changedAssets
            ? [...current.assets.filter((asset) => asset.work_item_id !== event.work_item_id), ...changedAssets]
            : current.assets;
          return { ...current, items, assets };
        });
        if (changedItem) setSelected((current) => current?.id === changedItem.id ? { ...changedItem, stage_id: current.stage_id } : current);
      }).catch(() => undefined);
    };
    source.addEventListener("board.change", applyChange);
    return () => {
      disposed = true;
      source.removeEventListener("board.change", applyChange);
      source.close();
      movementQueueMap.clear();
      movementVersionMap.clear();
    };
  }, [projectId]);
  useEffect(() => { const open = () => createControls.open(); window.addEventListener("agent-boards:add-item", open); return () => window.removeEventListener("agent-boards:add-item", open); }, [createControls]);
  async function move(itemId: string, stage: Stage) {
    if (!data) return;
    const before = data;
    setData({ ...data, items: data.items.map((item) => item.id === itemId ? { ...item, stage_id: stage.id } : item) });
    try {
      const changedItem = await api.moveItem(itemId, stage.slug);
      if (changedItem) {
        setData((current) => current ? {
          ...current,
          items: current.items.map((item) => item.id === itemId ? changedItem : item),
        } : current);
        setSelected((current) => current?.id === itemId ? changedItem : current);
      }
    }
    catch (error) { setData(before); notifications.show({ title: "Could not move card", message: error instanceof Error ? error.message : String(error), color: "alert" }); }
  }
  if (error) return <div className="page-state"><h2>Board unavailable</h2><p>{error}</p><Button onClick={load}>Try again</Button></div>;
  if (!data) return <BoardSkeleton />;
  return (
    <div className={`board-page${expanded ? " board-page--expanded" : ""}`}>
      <div className="page-head board-head">
        <h1>Kanban Delivery Board</h1>
        <div className="board-actions">
          <ActionIcon
            aria-label={expanded ? "Return board to centred width" : "Expand board to full width"}
            title={expanded ? "Return to centred width" : "Expand board to full width"}
            variant="default"
            size={36}
            onClick={() => setExpanded((current) => !current)}
          >
            {expanded ? <IconArrowsMinimize size={17} stroke={1.5} /> : <IconArrowsMaximize size={17} stroke={1.5} />}
          </ActionIcon>
        </div>
      </div>
      <KanbanBoard stages={data.stages} items={data.items} dependencies={data.dependencies} assets={data.assets} onMove={move} onOpen={setSelected} onChanged={load} />
      <CreateItemModal projectId={projectId} items={data.items} opened={creating} onClose={createControls.close} onCreated={load} />
      <ItemDrawer item={selected} items={data.items} stages={data.stages} dependencies={data.dependencies} opened={Boolean(selected)} onClose={() => setSelected(null)} onChanged={load} onSelectItem={setSelected} />
    </div>
  );
}
