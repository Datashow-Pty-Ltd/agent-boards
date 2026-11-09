import { SegmentedControl, TextInput } from "@mantine/core";
import { useDisclosure } from "@mantine/hooks";
import { IconSearch } from "@tabler/icons-react";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useParams } from "react-router";
import { api } from "../api";
import { CreateItemModal } from "../components/CreateItemModal";
import { ItemDrawer } from "../components/ItemDrawer";
import { BacklogSkeleton } from "../components/LoadingSkeletons";
import type { BoardData, WorkItem } from "../types";

type BacklogKind = "all" | "feature" | "story";

export function BacklogPage() {
  const { projectId = "" } = useParams();
  const [data, setData] = useState<BoardData | null>(null);
  const [query, setQuery] = useState("");
  const [kind, setKind] = useState<BacklogKind>("all");
  const [selected, setSelected] = useState<WorkItem | null>(null);
  const [creating, controls] = useDisclosure(false);
  const loadVersion = useRef(0);
  const load = useCallback(async () => {
    const version = loadVersion.current + 1;
    loadVersion.current = version;
    const core = await api.boardCore(projectId);
    if (loadVersion.current !== version) return;
    setData(core);
    setSelected((current) => current ? core.items.find((item) => item.id === current.id) ?? null : null);
    void api.boardDependencies(core.items).then((dependencies) => {
      if (loadVersion.current !== version) return;
      setData((current) => current ? { ...current, dependencies } : current);
    }).catch(() => undefined);
  }, [projectId]);
  useEffect(() => { setData(null); void load(); }, [load]);
  useEffect(() => { const open = () => controls.open(); window.addEventListener("agent-boards:add-item", open); return () => window.removeEventListener("agent-boards:add-item", open); }, [controls]);
  const rows = useMemo(() => data?.items.filter((item) =>
    item.kind !== "task"
    && (kind === "all" || item.kind === kind)
    && (!query || `${item.item_key} ${item.title} ${item.description}`.toLowerCase().includes(query.toLowerCase()))
  ) ?? [], [data, kind, query]);
  if (!data) return <BacklogSkeleton />;
  const stageById = new Map(data.stages.map((stage) => [stage.id, stage]));
  const itemById = new Map(data.items.map((item) => [item.id, item]));
  return <div className="content-page"><div className="page-head backlog-head"><h1>Backlog</h1></div>
    <div className="filter-bar"><TextInput className="work-search" size="md" leftSection={<IconSearch size={18} />} placeholder="Search backlog" aria-label="Search backlog" value={query} onChange={(e) => setQuery(e.currentTarget.value)} /><SegmentedControl className="backlog-type-segments" aria-label="Filter backlog by work type" value={kind} onChange={(value) => setKind(value as BacklogKind)} data={[{ value: "all", label: "All" }, { value: "feature", label: "Features" }, { value: "story", label: "Stories" }]} color="white" autoContrast withItemsBorders={false} styles={{ root: { height: 46, padding: 3, background: "var(--c-panel-2)", border: "1px solid var(--c-hair)" }, control: { height: 38 }, label: { minWidth: 82, height: 38, padding: "0 14px", color: "var(--c-ink-3)", fontFamily: "var(--f-sans)", fontSize: 14, fontWeight: 400, letterSpacing: 0, textTransform: "none" }, indicator: { height: 38, background: "var(--c-panel)", boxShadow: "0 1px 3px rgba(26,24,21,.1)" } }} /></div>
    <div className="data-table-wrap"><table className="data-table backlog-table"><thead><tr><th>Key</th><th>Work</th><th>Parent</th><th>Type</th><th>Stage</th><th>Owner</th><th>Worker</th><th>Priority</th><th className="num">Points</th></tr></thead><tbody>{rows.map((item) => { const parent = item.parent_id ? itemById.get(item.parent_id) : null; return <tr key={item.id} onClick={() => setSelected(item)}><td className="mono strong">{item.item_key}</td><td><strong>{item.title}</strong><span>{item.description}</span></td><td>{item.kind === "feature" ? <span className="feature-self">Top-level feature</span> : parent ? <span className="feature-link"><b>{parent.item_key} · {parent.kind}</b>{parent.title}</span> : <span className="unlinked">Unlinked</span>}</td><td className="mono">{item.kind}</td><td><span className="stage-tag">{stageById.get(item.stage_id)?.title}</span></td><td>{item.owner ?? "—"}</td><td>{item.assignee ?? "—"}</td><td className={`priority ${item.priority}`}>{item.priority}</td><td className="num">{item.estimate_points}</td></tr>; })}</tbody></table></div>
    <CreateItemModal projectId={projectId} items={data.items} opened={creating} onClose={controls.close} onCreated={load} /><ItemDrawer item={selected} items={data.items} stages={data.stages} dependencies={data.dependencies} opened={Boolean(selected)} onClose={() => setSelected(null)} onChanged={load} onSelectItem={setSelected} />
  </div>;
}
