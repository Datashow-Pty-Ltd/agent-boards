import { IconArrowLeft, IconArrowRight } from "@tabler/icons-react";
import useEmblaCarousel from "embla-carousel-react";
import { useCallback, useEffect, useMemo, useRef, useState, type WheelEvent } from "react";
import type { ProjectArtifact } from "../types";
import { ProjectDocumentModal } from "./ProjectDocumentModal";

const registerTypes = new Set(["risk_register", "issue_register"]);

function recordedDate(value: string) {
  return new Intl.DateTimeFormat("en-AU", { day: "numeric", month: "short", timeZone: "UTC" }).format(new Date(value)).toUpperCase();
}

function RecordCard({ record, projectName, onOpen }: { record: ProjectArtifact; projectName: string; onOpen: () => void }) {
  return <button type="button" className="project-record-card" onClick={onOpen}>
    <div className="project-record-thumbnail" aria-hidden="true">
      <div className="project-record-sheet">
        <span>{projectName}</span>
        <strong>{record.title}</strong>
        <i /><i /><i /><i />
      </div>
    </div>
    <div className="project-record-copy">
      <strong>{record.title}</strong>
      <span>{record.description}</span>
      <small>{record.artifact_type.endsWith("_register") ? record.status : `V${record.version}`} · {recordedDate(record.updated_at)} UTC</small>
    </div>
  </button>;
}

function RecordCarousel({ label, records, projectName, projectId, onOpen }: { label: string; records: ProjectArtifact[]; projectName: string; projectId: string; onOpen: (record: ProjectArtifact) => void }) {
  const [viewportRef, api] = useEmblaCarousel({ align: "start", containScroll: "trimSnaps", loop: false, duration: 20 });
  const [selected, setSelected] = useState(0);
  const [snapCount, setSnapCount] = useState(1);
  const [canPrevious, setCanPrevious] = useState(false);
  const [canNext, setCanNext] = useState(false);
  const wheelGestureActive = useRef(false);
  const wheelGestureTimer = useRef<number | null>(null);
  const update = useCallback(() => {
    setSelected(api?.selectedScrollSnap() ?? 0);
    setSnapCount(api?.scrollSnapList().length ?? 1);
    setCanPrevious(api?.canScrollPrev() ?? false);
    setCanNext(api?.canScrollNext() ?? false);
  }, [api]);

  useEffect(() => {
    if (!api) return;
    update();
    api.on("select", update).on("reInit", update);
    return () => { api.off("select", update).off("reInit", update); };
  }, [api, update]);

  useEffect(() => () => {
    if (wheelGestureTimer.current !== null) window.clearTimeout(wheelGestureTimer.current);
  }, []);

  const onWheel = useCallback((event: WheelEvent<HTMLDivElement>) => {
    if (!api) return;

    const movement = Math.abs(event.deltaX) >= Math.abs(event.deltaY)
      ? event.deltaX
      : event.shiftKey ? event.deltaY : 0;

    if (!movement) return;

    // Keep horizontal gestures inside the carousel and move by whole snaps. The
    // previous wheel plugin modelled edge resistance, which visibly pulled the
    // rail past its first and last records during trackpad momentum scrolling.
    event.preventDefault();

    if (wheelGestureTimer.current !== null) window.clearTimeout(wheelGestureTimer.current);
    wheelGestureTimer.current = window.setTimeout(() => {
      wheelGestureActive.current = false;
      wheelGestureTimer.current = null;
    }, 140);

    if (wheelGestureActive.current) return;
    wheelGestureActive.current = true;

    if (movement > 0 && api.canScrollNext()) api.scrollNext();
    if (movement < 0 && api.canScrollPrev()) api.scrollPrev();
  }, [api]);

  if (!records.length) return null;

  return <section className="project-record-carousel" aria-label={label} aria-roledescription="carousel">
    <div className="project-record-carousel-head">
      <span>{label}</span>
      <a href={`/api/project_artifacts?project_id=eq.${projectId}`}>View all →</a>
    </div>
    <div className="project-record-viewport" ref={viewportRef} onWheel={onWheel}>
      <div className="project-record-track">
        {records.map((record, index) => <article className="project-record-slide" role="group" aria-roledescription="slide" aria-label={`${index + 1} of ${records.length}`} key={record.id}>
          <RecordCard record={record} projectName={projectName} onOpen={() => onOpen(record)} />
        </article>)}
      </div>
    </div>
    <div className="project-record-controls">
      <div>
        <button type="button" aria-label={`Previous ${label.toLowerCase()}`} disabled={!canPrevious} onClick={() => api?.scrollPrev()}><IconArrowLeft size={18} stroke={1.6} /></button>
        <button type="button" aria-label={`Next ${label.toLowerCase()}`} disabled={!canNext} onClick={() => api?.scrollNext()}><IconArrowRight size={18} stroke={1.6} /></button>
      </div>
      <span>{selected + 1} / {snapCount}</span>
    </div>
  </section>;
}

export function ProjectRecordCarousels({ records, projectName, projectId, onRecordUpdated }: { records: ProjectArtifact[]; projectName: string; projectId: string; onRecordUpdated: (record: ProjectArtifact) => void }) {
  const [selectedRecord, setSelectedRecord] = useState<ProjectArtifact | null>(null);
  const { artifacts, registers } = useMemo(() => ({
    artifacts: records.filter((record) => !registerTypes.has(record.artifact_type)),
    registers: records.filter((record) => registerTypes.has(record.artifact_type)),
  }), [records]);

  return <div className="project-record-carousels">
    <RecordCarousel label="Project artefacts" records={artifacts} projectName={projectName} projectId={projectId} onOpen={setSelectedRecord} />
    <RecordCarousel label="Registers" records={registers} projectName={projectName} projectId={projectId} onOpen={setSelectedRecord} />
    <ProjectDocumentModal record={selectedRecord} onClose={() => setSelectedRecord(null)} onUpdated={(updated) => { setSelectedRecord(updated); onRecordUpdated(updated); }} />
  </div>;
}
