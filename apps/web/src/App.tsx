import { lazy, Suspense, useEffect, useState } from "react";
import { BrowserRouter, Link, NavLink, Navigate, Route, Routes, useLocation, useNavigate } from "react-router";
import { Button, Menu } from "@mantine/core";
import { notifications } from "@mantine/notifications";
import { useDisclosure } from "@mantine/hooks";
import { IconArchive, IconArchiveOff, IconChevronDown, IconPlus } from "@tabler/icons-react";
import { api } from "./api";
import { Brand } from "./components/Brand";
import { CreateProjectModal } from "./components/CreateProjectModal";
import { BacklogSkeleton, BoardSkeleton, ProjectOverviewSkeleton } from "./components/LoadingSkeletons";
import { ProjectArchiveModal } from "./components/ProjectArchiveModal";
import type { ProjectSummary } from "./types";

const BacklogPage = lazy(() => import("./pages/BacklogPage").then((module) => ({ default: module.BacklogPage })));
const BoardPage = lazy(() => import("./pages/BoardPage").then((module) => ({ default: module.BoardPage })));
const PortfolioPage = lazy(() => import("./pages/PortfolioPage").then((module) => ({ default: module.PortfolioPage })));
const ProjectOverviewPage = lazy(() => import("./pages/ProjectOverviewPage").then((module) => ({ default: module.ProjectOverviewPage })));

function RouteFallback({ pathname }: { pathname: string }) {
  if (pathname.endsWith("/board")) return <BoardSkeleton />;
  if (pathname.endsWith("/backlog")) return <BacklogSkeleton />;
  if (pathname.startsWith("/projects/")) return <ProjectOverviewSkeleton summary={null} />;
  return <div className="page-state" role="status">Loading projects</div>;
}

function Shell() {
  const [projects, setProjects] = useState<ProjectSummary[]>([]);
  const [loading, setLoading] = useState(true);
  const [projectAction, setProjectAction] = useState<"archive" | "restore" | null>(null);
  const [projectActionSaving, setProjectActionSaving] = useState(false);
  const [newProject, controls] = useDisclosure(false);
  const location = useLocation();
  const navigate = useNavigate();
  const projectId = location.pathname.match(/^\/projects\/([^/]+)/)?.[1];
  async function load() { setLoading(true); try { setProjects(await api.projects("all")); } finally { setLoading(false); } }
  useEffect(() => { void load(); }, []);
  const selected = projects.find((project) => project.project_id === projectId);
  const activeProjects = projects.filter((project) => project.status !== "archived");
  const projectBase = projectId && selected?.status !== "archived" ? `/projects/${projectId}` : null;
  const isWorkRoute = location.pathname.endsWith("/board") || location.pathname.endsWith("/backlog");
  async function changeProjectArchiveState() {
    if (!selected || !projectAction) return;
    setProjectActionSaving(true);
    try {
      if (projectAction === "archive") {
        await api.archiveProject(selected.project_id);
        notifications.show({ title: "Project archived", message: `${selected.name} is preserved in Archived projects.`, color: "accent" });
        navigate("/");
      } else {
        await api.restoreProject(selected.project_id);
        notifications.show({ title: "Project restored", message: `${selected.name} is active again.`, color: "accent" });
      }
      setProjectAction(null);
      await load();
    } catch (error) {
      notifications.show({ title: `Could not ${projectAction} project`, message: error instanceof Error ? error.message : String(error), color: "alert" });
    } finally {
      setProjectActionSaving(false);
    }
  }
  return <div className="app-shell">
    <header className="workspace-header">
      <Link to="/" className="brand-link"><Brand /></Link>
      <div className="breadcrumb-bar" aria-label="Breadcrumb">
        {selected &&
          <Menu position="bottom-start" width={300}>
            <Menu.Target><button className="project-switcher"><span>{selected.name}</span><IconChevronDown size={15} /></button></Menu.Target>
            <Menu.Dropdown>
              <Menu.Label>Projects</Menu.Label>
              {activeProjects.map((project) => <Menu.Item key={project.project_id} component={Link} to={`/projects/${project.project_id}`}>{project.project_key} · {project.name}</Menu.Item>)}
              <Menu.Divider />
              <Menu.Item component={Link} to="/?view=archived" leftSection={<IconArchive size={14} />}>Archived projects</Menu.Item>
              <Menu.Item leftSection={<IconPlus size={14} />} onClick={controls.open}>New project</Menu.Item>
              <Menu.Divider />
              {selected.status === "archived"
                ? <Menu.Item leftSection={<IconArchiveOff size={14} />} onClick={() => setProjectAction("restore")}>Restore project</Menu.Item>
                : <Menu.Item color="alert" leftSection={<IconArchive size={14} />} onClick={() => setProjectAction("archive")}>Archive project</Menu.Item>}
            </Menu.Dropdown>
          </Menu>
        }
      </div>
      <div className="workspace-controls">
        {projectBase && <nav className="view-segments" aria-label="Project views">
          <NavLink to={projectBase} end>Overview</NavLink>
          <NavLink to={`${projectBase}/board`}>Board</NavLink>
          <NavLink to={`${projectBase}/backlog`}>Backlog</NavLink>
        </nav>}
        {projectBase && isWorkRoute && <span className="control-divider" aria-hidden="true" />}
        {isWorkRoute ? <Button className="header-action" onClick={() => window.dispatchEvent(new Event("agent-boards:add-item"))} leftSection={<IconPlus size={15} />}>Add item</Button> : !projectId ? <Button className="header-action" onClick={controls.open} leftSection={<IconPlus size={15} />}>New project</Button> : null}
      </div>
    </header>
    <main className="main-content"><Suspense fallback={<RouteFallback pathname={location.pathname} />}><Routes><Route path="/" element={<PortfolioPage projects={projects} loading={loading} />} /><Route path="/projects/:projectId" element={<ProjectOverviewPage />} /><Route path="/projects/:projectId/board" element={selected?.status === "archived" ? <Navigate to={`/projects/${projectId}`} replace /> : <BoardPage />} /><Route path="/projects/:projectId/backlog" element={selected?.status === "archived" ? <Navigate to={`/projects/${projectId}`} replace /> : <BacklogPage />} /><Route path="/projects/:projectId/telemetry" element={<Navigate to={projectBase ?? "/"} replace />} /><Route path="*" element={<Navigate to="/" replace />} /></Routes></Suspense></main>
    <CreateProjectModal opened={newProject} onClose={controls.close} onCreated={load} />
    <ProjectArchiveModal
      project={selected ?? null}
      opened={projectAction !== null}
      restoring={projectAction === "restore"}
      saving={projectActionSaving}
      onClose={() => { if (!projectActionSaving) setProjectAction(null); }}
      onConfirm={() => { void changeProjectArchiveState(); }}
    />
  </div>;
}

export function App() { return <BrowserRouter><Routes><Route path="*" element={<Shell />} /></Routes></BrowserRouter>; }
