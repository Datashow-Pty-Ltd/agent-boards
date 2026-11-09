import type { Stage } from "./types";

export const KANBAN_PHASES = [
  { key: "backlog", title: "Backlog", stageSlugs: ["backlog"] },
  { key: "definition", title: "Define", stageSlugs: ["analyse", "plan"] },
  { key: "delivery", title: "Deliver", stageSlugs: ["build", "validate"] },
  { key: "integration", title: "Integrate", stageSlugs: ["review", "merge", "post_merge"] },
  { key: "complete", title: "Done", stageSlugs: ["done"] },
] as const;

export interface DeliveryPhase {
  key: string;
  title: string;
  stages: Stage[];
}

export function groupStagesIntoDeliveryPhases(stages: Stage[]): DeliveryPhase[] {
  const fallbackBySlug = new Map<string, (typeof KANBAN_PHASES)[number]>(KANBAN_PHASES.flatMap((phase) => phase.stageSlugs.map((slug) => [slug, phase] as const)));
  const grouped: DeliveryPhase[] = [];
  [...stages].sort((left, right) => left.position - right.position).forEach((stage) => {
    const fallback = fallbackBySlug.get(stage.slug);
    const key = stage.bucket_key || fallback?.key || "other";
    const title = stage.bucket_title || fallback?.title || "Other";
    const previous = grouped.at(-1);
    if (previous?.key === key) previous.stages.push(stage);
    else grouped.push({ key, title, stages: [stage] });
  });
  return grouped;
}
