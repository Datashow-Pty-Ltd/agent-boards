import { Button, Group, Modal, Stack, TextInput } from "@mantine/core";
import { notifications } from "@mantine/notifications";
import { IconChevronDown } from "@tabler/icons-react";
import { useEffect, useState, type ReactNode } from "react";
import { Link, useParams } from "react-router";
import { api } from "../api";
import { DeliveryPipelineChart } from "../components/DashboardCharts";
import { GutterRail } from "../components/GutterRail";
import { ActivitySkeleton, InlineSkeleton, ProjectOverviewSkeleton, RecordSkeleton } from "../components/LoadingSkeletons";
import { ProjectRecordCarousels } from "../components/ProjectRecordCarousel";
import { groupStagesIntoDeliveryPhases } from "../deliveryPhases";
import type { ActivityEvent, AgentMetrics, BoardData, ProjectArtifact, ProjectRepository, ProjectSummary } from "../types";

const SECTIONS = [
  ["project-identity", "The project"],
  ["project-actions", "Actions required"],
  ["project-delivery", "Current delivery"],
  ["project-health", "Delivery health"],
  ["project-plan", "Delivery plan"],
  ["project-record", "Project record"],
] as const;

function duration(ms: number) {
  const minutes = Math.round(ms / 60000);
  return minutes < 60 ? `${minutes}m` : `${Math.floor(minutes / 60)}h ${minutes % 60}m`;
}

function formatNumber(value: number) {
  return Intl.NumberFormat(undefined, { notation: value > 9999 ? "compact" : "standard", maximumFractionDigits: 1 }).format(value);
}

function relativeTime(value: string) {
  const seconds = Math.max(0, Math.round((Date.now() - new Date(value).getTime()) / 1000));
  if (seconds < 60) return "just now";
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m ago`;
  if (seconds < 86400) return `${Math.floor(seconds / 3600)}h ago`;
  return `${Math.floor(seconds / 86400)}d ago`;
}

function scrollToSection(id: string) {
  document.getElementById(id)?.scrollIntoView({ behavior: "smooth", block: "start" });
}

function SectionHead({ eyebrow, title, emphasis, description }: { eyebrow: string; title: string; emphasis?: string; description: ReactNode }) {
  return <div className="command-section-head">
    <div><div className="section-label">{eyebrow}</div><h2>{title} {emphasis && <em>{emphasis}</em>}</h2></div>
    <p>{description}</p>
  </div>;
}

export function ProjectOverviewPage() {
  const { projectId = "" } = useParams();
  const [summary, setSummary] = useState<ProjectSummary | null>(null);
  const [activity, setActivity] = useState<ActivityEvent[] | null>(null);
  const [agentMetrics, setAgentMetrics] = useState<AgentMetrics | null | undefined>(undefined);
  const [board, setBoard] = useState<BoardData | null>(null);
  const [artifacts, setArtifacts] = useState<ProjectArtifact[] | null>(null);
  const [repository, setRepository] = useState<ProjectRepository | null | undefined>(undefined);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [repositoryEditorOpen, setRepositoryEditorOpen] = useState(false);
  const [repositoryUrl, setRepositoryUrl] = useState("");
  const [repositoryBranch, setRepositoryBranch] = useState("main");
  const [repositorySaving, setRepositorySaving] = useState(false);
  const [expandedFeature, setExpandedFeature] = useState<string | null>(null);
  const [showAllActivity, setShowAllActivity] = useState(false);

  useEffect(() => {
    let disposed = false;
    setSummary(null);
    setBoard(null);
    setActivity(null);
    setAgentMetrics(undefined);
    setArtifacts(null);
    setRepository(undefined);
    setLoadError(null);

    void api.project(projectId).then((project) => {
      if (disposed) return;
      if (!project) throw new Error("Project not found.");
      setSummary(project);
    }).catch((error) => { if (!disposed) setLoadError(error instanceof Error ? error.message : String(error)); });

    void api.boardCore(projectId).then((boardData) => {
      if (disposed) return;
      setBoard(boardData);
      setExpandedFeature(boardData.items.find((item) => item.kind === "feature")?.id ?? null);
    }).catch((error) => { if (!disposed) setLoadError(error instanceof Error ? error.message : String(error)); });

    void api.activities(projectId).then((events) => { if (!disposed) setActivity(events); }).catch(() => { if (!disposed) setActivity([]); });
    void api.agentMetrics(projectId).then((metrics) => { if (!disposed) setAgentMetrics(metrics); }).catch(() => { if (!disposed) setAgentMetrics(null); });
    void api.artifacts(projectId).then((records) => { if (!disposed) setArtifacts(records); }).catch(() => { if (!disposed) setArtifacts([]); });
    void api.projectRepository(projectId).then((projectRepository) => { if (!disposed) setRepository(projectRepository); }).catch(() => { if (!disposed) setRepository(null); });

    return () => { disposed = true; };
  }, [projectId]);

  function openRepositoryEditor() {
    setRepositoryUrl(repository?.repository_url ?? "");
    setRepositoryBranch(repository?.default_branch ?? "main");
    setRepositoryEditorOpen(true);
  }

  async function saveRepository() {
    if (!repositoryUrl.trim() || !repositoryBranch.trim()) return;
    setRepositorySaving(true);
    try {
      const records = await api.setProjectRepository(projectId, repositoryUrl.trim(), repositoryBranch.trim());
      setRepository(records[0] ?? null);
      setRepositoryEditorOpen(false);
      notifications.show({ title: "Repository linked", message: records[0]?.full_name ?? repositoryUrl.trim(), color: "accent" });
    } catch (error) {
      notifications.show({ title: "Could not link repository", message: error instanceof Error ? error.message : String(error), color: "alert" });
    } finally {
      setRepositorySaving(false);
    }
  }

  async function removeRepository() {
    setRepositorySaving(true);
    try {
      await api.removeProjectRepository(projectId);
      setRepository(null);
      setRepositoryEditorOpen(false);
      notifications.show({ title: "Repository unlinked", message: "The project no longer points to a source repository.", color: "accent" });
    } catch (error) {
      notifications.show({ title: "Could not unlink repository", message: error instanceof Error ? error.message : String(error), color: "alert" });
    } finally {
      setRepositorySaving(false);
    }
  }

  if (loadError) return <div className="page-state"><h2>Project unavailable</h2><p>{loadError}</p></div>;
  if (!summary || !board) return <ProjectOverviewSkeleton summary={summary} />;

  const projectBase = `/projects/${projectId}`;
  const features = board.items.filter((item) => item.kind === "feature");
  const stories = board.items.filter((item) => item.kind === "story");
  const tasks = board.items.filter((item) => item.kind === "task");
  const backlogStageId = board.stages.find((stage) => stage.slug === "backlog")?.id;
  const inProgressItems = board.items.filter((item) =>
    item.kind !== "task" && item.progress !== "completed" && item.stage_id !== backlogStageId
  ).length;
  const humanItems = board.items.filter((item) => ["waiting_for_human", "blocked", "failed"].includes(item.execution_state ?? ""));
  const pct = summary.total_points ? Math.round((summary.completed_points / summary.total_points) * 100) : 0;
  const acceptanceTotal = board.items.reduce((count, item) => count + item.acceptance_criteria.length, 0);
  const acceptanceComplete = board.items.reduce((count, item) => count + item.acceptance_criteria.filter((criterion) => criterion.status === "passed").length, 0);
  const checklistTotal = board.items.reduce((count, item) => count + item.checklist.length, 0);
  const checklistComplete = board.items.reduce((count, item) => count + item.checklist.filter((entry) => entry.checked).length, 0);
  const confidence = Math.max(0, Math.round(((board.items.length - humanItems.length) / Math.max(1, board.items.length)) * 100));
  const urgentOpen = board.items.filter((item) => item.progress !== "completed" && ["urgent", "high"].includes(item.priority)).length;
  const acceptancePercent = acceptanceTotal ? Math.round(acceptanceComplete / acceptanceTotal * 100) : 0;
  const checklistPercent = checklistTotal ? Math.round(checklistComplete / checklistTotal * 100) : 0;
  const openQuestions = humanItems.length;
  const runningStory = stories.find((item) => item.execution_state === "running");
  const currentFeature = features.find((item) => item.id === runningStory?.parent_id) ?? features[0];
  const deliveryPhases = groupStagesIntoDeliveryPhases(board.stages);
  const archived = summary.status === "archived";
  const claimSessions = Number(agentMetrics?.claim_session_count ?? 0);
  const reportedTokens = Number(agentMetrics?.input_tokens ?? 0) + Number(agentMetrics?.output_tokens ?? 0);
  const hasReportedTokens = Number(agentMetrics?.token_reported_sessions ?? 0) > 0;
  const hasReportedCost = Number(agentMetrics?.cost_reported_sessions ?? 0) > 0;
  const usageCoverage = `${Number(agentMetrics?.usage_reported_sessions ?? 0)}/${claimSessions} sessions`;

  return <>
    <div className="content-page project-command-page">
      <main className="project-command-main">
        {archived && <div className="project-alert-stack">
          <div className="project-alert-strip archived" role="status">
            <span>Archived project · work is read-only</span>
            <span>Restore it from the project menu to continue</span>
          </div>
        </div>}
        {!archived && (humanItems.length > 0 || summary.running_items > 0) && <div className="project-alert-stack">
          {humanItems.length > 0 && <div className="project-alert-strip alert" role="alert">
            <span>{humanItems.length} {humanItems.length === 1 ? "item needs" : "items need"} attention</span>
            <a href="#project-actions" onClick={(event) => { event.preventDefault(); scrollToSection("project-actions"); }}>Review work →</a>
          </div>}
          {summary.running_items > 0 && <div className="project-alert-strip running" role="status">
            <span><i aria-hidden="true" />{summary.running_items} {summary.running_items === 1 ? "agent is" : "agents are"} working now</span>
            <a href="#project-delivery" onClick={(event) => { event.preventDefault(); scrollToSection("project-delivery"); }}>See delivery →</a>
          </div>}
        </div>}

        <section id="project-identity" data-rail-anchor="project-identity" className="project-identity-section command-section">
          <div className="project-identity-title">
            <div className="project-identity-main"><h1>{summary.name}</h1></div>
            <div className="project-meta-line"><span>Updated {relativeTime(summary.updated_at)}</span></div>
          </div>
          <div className="project-kpi-grid">
            <div><span>Progress</span><strong>{pct}%</strong><small>{summary.completed_points} / {summary.total_points} points</small></div>
            <div><span>Current feature</span><strong className="kpi-text">{currentFeature?.title ?? "Not assigned"}</strong><small>{features.length} feature{features.length === 1 ? "" : "s"}</small></div>
            <div><span>Agents working</span><strong>{summary.running_items}</strong><small>right now</small></div>
            <div className={humanItems.length ? "attention" : ""}><span>Needs a person</span><strong>{humanItems.length}</strong><small>action required</small></div>
            <div><span>Agent spend</span>{agentMetrics === undefined
              ? <InlineSkeleton className="kpi-inline-skeleton" />
              : hasReportedCost || hasReportedTokens
                ? <><strong>{hasReportedCost ? `$${Number(agentMetrics?.estimated_cost_usd ?? 0).toFixed(2)}` : "—"}</strong><small>{hasReportedTokens ? `${formatNumber(reportedTokens)} reported tokens · ${usageCoverage}` : `Cost reported · ${usageCoverage}`}</small></>
                : <><strong>—</strong><small>Usage not reported</small></>}</div>
            <div><span>Agent time</span>{agentMetrics === undefined
              ? <InlineSkeleton className="kpi-inline-skeleton" />
              : claimSessions > 0
                ? <><strong>{duration(Number(agentMetrics?.claimed_duration_ms ?? 0))}</strong><small>{claimSessions} claimed {claimSessions === 1 ? "session" : "sessions"}</small></>
                : <><strong>—</strong><small>No tracked sessions</small></>}</div>
          </div>
          <div className="project-brief-grid">
            <div><div className="section-label">Project brief</div><p>{summary.description}</p></div>
            <div className="project-source-card">
              <div className="project-source-card-head"><h3>Source repository</h3></div>
              <div className="project-source-card-body">
                <div className="project-source-card-link">
                  {repository === undefined
                    ? <InlineSkeleton className="source-inline-skeleton" />
                    : repository
                    ? <a href={repository.repository_url} target="_blank" rel="noreferrer">{repository.full_name}</a>
                    : <span>No repository connected</span>}
                  {repository !== undefined && <button type="button" onClick={openRepositoryEditor}>{repository ? "Change" : "Connect"}</button>}
                </div>
                {repository && <span className="project-source-card-state"><i aria-hidden="true" />{repository.provider} · {repository.default_branch}</span>}
              </div>
            </div>
          </div>
        </section>

        {humanItems.length > 0 && <section id="project-actions" data-rail-anchor="project-actions" className="command-section">
          <SectionHead eyebrow="Attention" title="Work needing" emphasis="attention" description={<><strong>{humanItems.length} {humanItems.length === 1 ? "item" : "items"}</strong> need review before delivery can move cleanly.</>} />
          <div className="attention-card">
            <div className="attention-card-body">
              {humanItems.slice(0, 8).map((item) => {
                const stage = board.stages.find((entry) => entry.id === item.stage_id);
                const status = item.execution_state === "waiting_for_human" ? "Waiting on human" : item.execution_state === "failed" ? "Failed" : "Blocked";
                return <div className="attention-item" key={item.id}>
                  <i className="attention-dot" aria-hidden="true" />
                  <div>
                    <Link to={`${projectBase}/board?item=${item.id}`}>{item.title}</Link>
                    <span>{stage?.title}{item.blocked_reason ? ` · ${item.blocked_reason}` : ""}</span>
                  </div>
                  <b>{status}</b>
                </div>;
              })}
            </div>
            <div className="attention-card-foot"><span>{humanItems.length > 8 ? `${humanItems.length - 8} more items on the board` : "Open an item to review what stopped it"}</span><Link to={`${projectBase}/board`}>Open board →</Link></div>
          </div>
        </section>}

        <section id="project-delivery" data-rail-anchor="project-delivery" className="command-section">
          <SectionHead eyebrow="Current delivery" title="What is moving" emphasis="now" description={<><strong>{inProgressItems} {inProgressItems === 1 ? "item" : "items"}</strong> in progress.</>} />
          <div className="delivery-flow-card">
            <div className="compact-stage-stats">{deliveryPhases.map((phase) => <div key={phase.key}><span>{phase.title}</span><strong>{board.items.filter((item) => item.kind !== "task" && phase.stages.some((stage) => item.stage_id === stage.id)).length}</strong></div>)}</div>
            <DeliveryPipelineChart stages={board.stages} items={board.items} />
            <div className="command-card-foot"><span>Features and stories by Kanban lane</span><Link to={`${projectBase}/board`}>Open board →</Link></div>
          </div>
          <div className="recent-activity-block">
            <div className="recent-activity-head"><h3>Recent activity</h3><button type="button" onClick={() => setShowAllActivity((current) => !current)}>{showAllActivity ? "Show recent" : "View all"}</button></div>
            <table className="recent-activity-table" aria-label="Recent project activity">
              <colgroup><col className="activity-dot-column" /><col /><col className="activity-time-column" /></colgroup>
              {activity === null ? <ActivitySkeleton /> : <tbody>{activity.slice(0, showAllActivity ? activity.length : 5).map((event) => {
                const item = board.items.find((entry) => entry.id === event.work_item_id);
                return <tr key={event.id}>
                  <td><i className={`activity-dot ${event.actor_type}`} aria-hidden="true" /></td>
                  <td><div>{event.summary}</div><span>{event.actor_name}{item ? ` · ${item.title}` : ""}</span></td>
                  <td><span>{relativeTime(event.created_at)}</span></td>
                </tr>;
              })}</tbody>}
            </table>
          </div>
        </section>

        <section id="project-health" data-rail-anchor="project-health" className="command-section">
          <SectionHead eyebrow="Delivery health" title="How the work is" emphasis="holding up" description="Drawn from the work items themselves — the checks agents have signed off, and what they said about their own confidence." />
          <div className="health-grid">
            <article className="health-card">
              <header><h3>Acceptance checks</h3><strong>{acceptanceTotal ? `${acceptanceComplete}/${acceptanceTotal}` : "—"}</strong></header>
              <div className="health-card-body health-progress"><span><i style={{ width: `${acceptancePercent}%` }} /></span><b>{acceptancePercent}%</b></div>
              <footer>Criteria signed off across every item</footer>
            </article>
            <article className="health-card">
              <header><h3>Task checklists</h3><strong>{checklistTotal ? `${checklistComplete}/${checklistTotal}` : "—"}</strong></header>
              <div className="health-card-body health-progress"><span><i style={{ width: `${checklistPercent}%` }} /></span><b>{checklistPercent}%</b></div>
              <footer>Steps ticked inside the work</footer>
            </article>
            <article className="health-card">
              <header><h3>Confidence</h3><strong>{confidence}<i>%</i></strong></header>
              <div className="health-card-body health-confidence">Average across {board.items.length} scored {board.items.length === 1 ? "item" : "items"}.</div>
              <footer>What the agents said about their own work</footer>
            </article>
            <article className="health-card">
              <header><h3>Risk and questions</h3><strong>{urgentOpen + openQuestions}</strong></header>
              <div className="health-card-body health-risks">
                <div><b className={urgentOpen ? "alert" : ""}>{urgentOpen}</b><span>High or critical risk</span></div>
                <div><b className={openQuestions ? "alert" : ""}>{openQuestions}</b><span>Questions still open</span></div>
              </div>
              <footer>Flagged by the work itself</footer>
            </article>
          </div>
        </section>

        <section id="project-plan" data-rail-anchor="project-plan" className="command-section">
          <SectionHead eyebrow="Delivery plan" title="Features and their" emphasis="work" description="The hierarchy stays visible: every story belongs to a feature, and its tasks remain attached to the story." />
          <div className="delivery-plan">
            {features.map((feature) => {
              const featureStories = stories.filter((story) => story.parent_id === feature.id);
              const open = expandedFeature === feature.id;
              return <div className="plan-feature" key={feature.id}>
                <button type="button" onClick={() => setExpandedFeature(open ? null : feature.id)}><span><i>{feature.item_key}</i><strong>{feature.title}</strong></span><span>{featureStories.length} stories <IconChevronDown className={open ? "rotated" : ""} size={16} /></span></button>
                {open && <div className="plan-story-list">{featureStories.map((story) => {
                  const storyTasks = tasks.filter((task) => task.parent_id === story.id);
                  const stage = board.stages.find((entry) => entry.id === story.stage_id);
                  return <Link to={`${projectBase}/board?item=${story.id}`} key={story.id}><span>{story.item_key}</span><div><strong>{story.title}</strong><small>{storyTasks.length} task{storyTasks.length === 1 ? "" : "s"} · {story.estimate_points} points</small></div><i>{stage?.title}</i></Link>;
                })}</div>}
              </div>;
            })}
          </div>
        </section>

        <section id="project-record" data-rail-anchor="project-record" className="command-section">
          <SectionHead eyebrow="Project record" title="What the work is" emphasis="based on" description="Artefacts are outputs Agent Boards has produced. Registers are the assumptions, decisions, risks and issues it maintains while controlling delivery." />
          {artifacts === null ? <RecordSkeleton /> : <ProjectRecordCarousels
            records={artifacts}
            projectName={summary.name}
            projectId={projectId}
            onRecordUpdated={(updated) => setArtifacts((current) => (current ?? []).map((record) => record.id === updated.id ? updated : record))}
          />}
        </section>
      </main>
      <GutterRail title="Contents" items={SECTIONS.filter(([id]) => id !== "project-actions" || humanItems.length > 0).map(([id, label]) => ({ id, label }))} />
    </div>
    <Modal opened={repositoryEditorOpen} onClose={() => setRepositoryEditorOpen(false)} title={<span className="modal-title">Source repository</span>} size="lg">
      <Stack gap="md">
        <TextInput
          label="Repository URL"
          description="Use the HTTPS URL for the repository, including its owner or organisation."
          placeholder="https://github.com/organisation/repository"
          value={repositoryUrl}
          onChange={(event) => setRepositoryUrl(event.currentTarget.value)}
          autoFocus
        />
        <TextInput label="Default branch" value={repositoryBranch} onChange={(event) => setRepositoryBranch(event.currentTarget.value)} />
        <Group justify="space-between">
          <div>{repository && <Button variant="subtle" color="alert" loading={repositorySaving} onClick={removeRepository}>Unlink</Button>}</div>
          <Group><Button onClick={() => setRepositoryEditorOpen(false)}>Cancel</Button><Button variant="filled" color="accent" loading={repositorySaving} disabled={!repositoryUrl.trim() || !repositoryBranch.trim()} onClick={saveRepository}>Save repository</Button></Group>
        </Group>
      </Stack>
    </Modal>
  </>;
}
