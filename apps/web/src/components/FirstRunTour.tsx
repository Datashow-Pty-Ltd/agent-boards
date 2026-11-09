import { Button, Modal } from "@mantine/core";
import { IconChecklist, IconGitMerge, IconRobot, IconTimelineEvent } from "@tabler/icons-react";
import { useEffect, useState } from "react";

const TOUR_STORAGE_KEY = "agent-boards:first-run-tour:v1";

const screens = [
  {
    eyebrow: "One durable project record",
    title: "The board is the source of truth",
    body: "Features, stories, tasks, dependencies, comments and evidence stay together. Humans and connected agents read and update the same record.",
    icon: IconTimelineEvent,
  },
  {
    eyebrow: "Governed delivery",
    title: "Work advances one gate at a time",
    body: "Stories move through definition, delivery and integration. Each stage exposes the exact exit criteria required before the next transition.",
    icon: IconGitMerge,
  },
  {
    eyebrow: "Agent workflow",
    title: "Agents claim only ready work",
    body: "An agent asks for the next unblocked story, receives its tasks, invariants and acceptance criteria, then records progress and proof as it works.",
    icon: IconRobot,
  },
  {
    eyebrow: "Inspectable completion",
    title: "Evidence closes the loop",
    body: "Validation, review, merge and post-merge checks are attached to the exact revision. Visual work can also require approved mockups, screenshots or interaction recordings.",
    icon: IconChecklist,
  },
] as const;

function rememberTour() {
  try { window.localStorage.setItem(TOUR_STORAGE_KEY, "complete"); } catch { /* Storage can be disabled. */ }
}

export function FirstRunTour() {
  const [opened, setOpened] = useState(false);
  const [screen, setScreen] = useState(0);

  useEffect(() => {
    try { setOpened(window.localStorage.getItem(TOUR_STORAGE_KEY) !== "complete"); } catch { setOpened(true); }
    const replay = () => { setScreen(0); setOpened(true); };
    window.addEventListener("agent-boards:show-tour", replay);
    return () => window.removeEventListener("agent-boards:show-tour", replay);
  }, []);

  const current = screens[screen];
  const Icon = current.icon;
  function finish() { rememberTour(); setOpened(false); }

  return <Modal opened={opened} onClose={finish} size="lg" centered title="Welcome to Agent Boards" classNames={{ content: "tour-modal", header: "tour-modal-header", body: "tour-modal-body" }}>
    <div className="tour-progress" aria-label={`Tour screen ${screen + 1} of ${screens.length}`}>
      {screens.map((entry, index) => <i key={entry.title} className={index <= screen ? "active" : ""} />)}
    </div>
    <section className="tour-screen">
      <Icon size={34} stroke={1.4} aria-hidden="true" />
      <span className="eyebrow">{current.eyebrow}</span>
      <h2>{current.title}</h2>
      <p>{current.body}</p>
    </section>
    <div className="tour-actions">
      <Button variant="subtle" onClick={finish}>Skip tour</Button>
      <div>
        {screen > 0 && <Button onClick={() => setScreen((value) => value - 1)}>Back</Button>}
        <Button onClick={() => screen === screens.length - 1 ? finish() : setScreen((value) => value + 1)}>{screen === screens.length - 1 ? "Start using Agent Boards" : "Next"}</Button>
      </div>
    </div>
  </Modal>;
}
