import { ResponsiveFunnel } from "@nivo/funnel";
import { groupStagesIntoDeliveryPhases } from "../deliveryPhases";
import type { Stage, WorkItem } from "../types";

const stageColors = ["#cd8693", "#e6c1c2", "#dfd6c4", "#a8c4c0", "#5fa1a0", "#2e7e83", "#155961"];

export function DeliveryPipelineChart({ stages, items }: { stages: Stage[]; items: WorkItem[] }) {
  const phases = groupStagesIntoDeliveryPhases(stages);
  const rows = phases.map((phase, index) => ({
    category: phase.title,
    value: items.filter((item) => phase.stages.some((stage) => item.stage_id === stage.id) && item.kind !== "task").length,
    color: stageColors[index] ?? "#837e74",
  }));

  return <div className="dashboard-chart-host pipeline-chart" aria-label="Current delivery pipeline chart">
    <ResponsiveFunnel
      data={rows.map((row) => ({ id: row.category, value: row.value, color: row.color }))}
      margin={{ top: 8, right: 8, bottom: 8, left: 8 }}
      direction="horizontal"
      colors={(datum) => datum.color}
      borderWidth={0}
      enableLabel={false}
      enableBeforeSeparators={false}
      enableAfterSeparators={false}
      isInteractive={false}
      animate={false}
    />
  </div>;
}
