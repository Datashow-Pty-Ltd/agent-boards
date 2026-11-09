import type { ProjectSummary } from "../types";

const skeletonConfig = JSON.stringify({ animation: "wave", theme: "light", opacity: "1", borderRadius: "0" });

function Bone({ className = "" }: { className?: string }) {
  return <span className={`sm-item-secondary loading-bone ${className}`} aria-hidden="true" />;
}

function SectionSkeleton({ cards = 1 }: { cards?: number }) {
  return <section className="command-section loading-command-section">
    <div className="command-section-head">
      <div><Bone className="bone-eyebrow" /><Bone className="bone-section-title" /></div>
      <div className="loading-description"><Bone /><Bone className="short" /></div>
    </div>
    <div className={`loading-section-cards cards-${cards}`}>
      {Array.from({ length: cards }, (_, index) => <div className="sm-item-primary loading-panel" key={index} />)}
    </div>
  </section>;
}

export function ProjectOverviewSkeleton({ summary }: { summary: ProjectSummary | null }) {
  return <div className="content-page project-command-page project-loading sm-loading" data-sm-config={skeletonConfig} aria-busy="true" aria-label="Loading project">
    <main className="project-command-main">
      <section className="project-identity-section command-section">
        <div className="project-identity-title">
          <div className="project-identity-main">{summary ? <h1>{summary.name}</h1> : <Bone className="bone-project-title" />}</div>
          <Bone className="bone-updated" />
        </div>
        <div className="project-kpi-grid loading-kpi-grid">
          {Array.from({ length: 6 }, (_, index) => <div key={index}><Bone className="bone-kpi-label" /><Bone className="bone-kpi-value" /><Bone className="bone-kpi-copy" /></div>)}
        </div>
        <div className="project-brief-grid">
          <div>
            <Bone className="bone-eyebrow" />
            {summary ? <p>{summary.description}</p> : <div className="loading-copy"><Bone /><Bone /><Bone className="short" /></div>}
          </div>
          <div className="project-source-card loading-source-card"><Bone className="bone-source-title" /><Bone className="bone-source-copy" /><Bone className="bone-source-state" /></div>
        </div>
      </section>
      <SectionSkeleton />
      <SectionSkeleton cards={4} />
      <SectionSkeleton />
      <SectionSkeleton cards={4} />
    </main>
    <span className="visually-hidden" role="status">Loading project content</span>
  </div>;
}

export function BoardSkeleton() {
  return <div className="board-page board-loading sm-loading" data-sm-config={skeletonConfig} aria-busy="true" aria-label="Loading delivery board">
    <div className="page-head board-head"><h1>Kanban Delivery Board</h1><Bone className="bone-board-action" /></div>
    <div className="loading-board-grid">
      {Array.from({ length: 5 }, (_, column) => <section key={column}><header><Bone className="bone-lane-title" /><Bone className="bone-lane-count" /></header>{Array.from({ length: column === 3 ? 3 : 2 }, (_, card) => <div className="sm-item-primary loading-board-card" key={card}><Bone /><Bone className="short" /><Bone className="tiny" /></div>)}</section>)}
    </div>
    <span className="visually-hidden" role="status">Loading delivery board</span>
  </div>;
}

export function BacklogSkeleton() {
  return <div className="content-page backlog-loading sm-loading" data-sm-config={skeletonConfig} aria-busy="true" aria-label="Loading backlog">
    <div className="page-head backlog-head"><h1>Backlog</h1></div>
    <div className="filter-bar"><Bone className="bone-search" /><Bone className="bone-segments" /></div>
    <div className="loading-table">
      <Bone className="bone-table-head" />
      {Array.from({ length: 8 }, (_, row) => <div key={row}>{Array.from({ length: 6 }, (_, cell) => <Bone className={cell === 1 ? "wide" : ""} key={cell} />)}</div>)}
    </div>
    <span className="visually-hidden" role="status">Loading backlog</span>
  </div>;
}

export function InlineSkeleton({ className = "" }: { className?: string }) {
  return <span className={`inline-loading sm-loading ${className}`} data-sm-config={skeletonConfig}><Bone /></span>;
}

export function ActivitySkeleton() {
  return <tbody className="activity-loading sm-loading" data-sm-config={skeletonConfig}>{Array.from({ length: 5 }, (_, row) => <tr key={row}><td><Bone className="bone-activity-dot" /></td><td><Bone className="bone-activity-title" /><Bone className="bone-activity-meta" /></td><td><Bone className="bone-activity-time" /></td></tr>)}</tbody>;
}

export function RecordSkeleton() {
  return <div className="record-loading sm-loading" data-sm-config={skeletonConfig}>{Array.from({ length: 4 }, (_, index) => <div className="sm-item-primary" key={index}><Bone className="bone-record-image" /><Bone className="bone-record-title" /><Bone /><Bone className="short" /></div>)}</div>;
}
