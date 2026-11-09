import { describe, expect, it } from "vitest";
import { groupStagesIntoDeliveryPhases } from "./deliveryPhases";
import type { Stage } from "./types";

function stage(slug: string, position: number, bucketKey: string, bucketTitle: string): Stage {
  return {
    id: slug,
    board_id: "board",
    slug,
    title: slug,
    position,
    bucket_key: bucketKey,
    bucket_title: bucketTitle,
    purpose: "",
    responsible_actor: "Team",
    wip_limit: null,
    entry_criteria: [],
    exit_criteria: [],
    allowed_transitions: [],
  };
}

describe("delivery phase grouping", () => {
  it("uses durable bucket settings in stage order", () => {
    const phases = groupStagesIntoDeliveryPhases([
      stage("build", 2, "make", "Make"),
      stage("backlog", 0, "queue", "Queue"),
      stage("plan", 1, "make", "Make"),
      stage("done", 3, "done", "Done"),
    ]);

    expect(phases.map((phase) => ({ key: phase.key, title: phase.title, stages: phase.stages.map((entry) => entry.slug) }))).toEqual([
      { key: "queue", title: "Queue", stages: ["backlog"] },
      { key: "make", title: "Make", stages: ["plan", "build"] },
      { key: "done", title: "Done", stages: ["done"] },
    ]);
  });
});
