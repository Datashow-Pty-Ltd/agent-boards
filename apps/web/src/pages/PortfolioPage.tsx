import { Loader } from "@mantine/core";
import { IconArchive, IconArrowLeft, IconArrowRight } from "@tabler/icons-react";
import { Link, useSearchParams } from "react-router";
import type { ProjectSummary } from "../types";

export function PortfolioPage({ projects, loading }: { projects: ProjectSummary[]; loading: boolean }) {
  const [searchParams] = useSearchParams();
  if (loading) return <div className="page-state"><Loader color="accent" size="sm" /> Loading projects</div>;
  const showingArchived = searchParams.get("view") === "archived";
  const activeProjects = projects.filter((project) => project.status !== "archived");
  const archivedProjects = projects.filter((project) => project.status === "archived");
  const visibleProjects = showingArchived ? archivedProjects : activeProjects;
  const totals = visibleProjects.reduce((acc, project) => ({ items: acc.items + Number(project.total_items), done: acc.done + Number(project.completed_items), active: acc.active + Number(project.running_items), blocked: acc.blocked + Number(project.blocked_items) }), { items: 0, done: 0, active: 0, blocked: 0 });
  return <div className="content-page"><div className="page-head portfolio-page-head"><div><div className="eyebrow">Portfolio</div><h1>{showingArchived ? "Archived projects" : "Project delivery"}</h1><p>{showingArchived ? "Preserved project records that are no longer active." : "One shared view of work performed by people and agents."}</p></div>
    {showingArchived
      ? <Link className="portfolio-view-link" to="/"><IconArrowLeft size={15} /> Active projects</Link>
      : <Link className="portfolio-view-link" to="/?view=archived"><IconArchive size={15} /> Archived projects <span>{archivedProjects.length}</span></Link>}
    </div>
    {!showingArchived && <div className="metric-grid"><div className="metric"><span>Projects</span><strong>{visibleProjects.length}</strong><small>active records</small></div><div className="metric"><span>Work items</span><strong>{totals.items}</strong><small>{totals.done} complete</small></div><div className="metric"><span>Agents working</span><strong>{totals.active}</strong><small>recorded now</small></div><div className={`metric ${totals.blocked ? "alert" : ""}`}><span>Needs attention</span><strong>{totals.blocked}</strong><small>blocked or waiting</small></div></div>}
    {visibleProjects.length === 0
      ? <div className="portfolio-empty"><IconArchive size={22} /><strong>{showingArchived ? "No archived projects" : "No active projects"}</strong><span>{showingArchived ? "Projects you archive will remain available here." : "Create a project to start a governed delivery board."}</span></div>
      : <div className="project-grid">{visibleProjects.map((project) => { const percent = project.total_points ? Math.round((project.completed_points / project.total_points) * 100) : 0; return <Link className={`project-card${project.status === "archived" ? " archived" : ""}`} key={project.project_id} to={`/projects/${project.project_id}`}><div className="project-card-head"><span className="project-key">{project.project_key}</span><span className={`status ${project.status}`}>{project.status}</span></div><h2>{project.name}</h2><p>{project.description}</p><div className="progress-line"><i style={{ width: `${percent}%` }} /></div><div className="project-card-foot"><span><strong>{percent}%</strong> · {project.completed_points}/{project.total_points} points</span><IconArrowRight size={18} /></div></Link>; })}</div>}
  </div>;
}
