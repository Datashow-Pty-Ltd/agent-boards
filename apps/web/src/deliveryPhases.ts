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
  const assigned = new Set<string>();
  const grouped: DeliveryPhase[] = KANBAN_PHASES.map((phase) => {
    const phaseStages = phase.stageSlugs
      .map((slug) => stages.find((stage) => stage.slug === slug))
      .filter((stage): stage is Stage => stage !== undefined);
    phaseStages.forEach((stage) => assigned.add(stage.id));
    return { key: phase.key, title: phase.title, stages: phaseStages };
  }).filter((phase) => phase.stages.length > 0);

  const unassigned = stages.filter((stage) => !assigned.has(stage.id));
  if (unassigned.length > 0) {
    grouped.splice(Math.max(0, grouped.length - 1), 0, { key: "other", title: "Other", stages: unassigned });
  }
  return grouped;
}
