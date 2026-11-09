import { Button, Modal } from "@mantine/core";
import { IconCheck, IconChecklist, IconCopy, IconGitMerge, IconPlugConnected, IconRobot, IconTimelineEvent } from "@tabler/icons-react";
import { useEffect, useState } from "react";

const TOUR_STORAGE_KEY = "agent-boards:first-run-tour:v1";
const AGENT_INSTRUCTION = "Use the Agent Boards MCP server as the source of truth for this project. List the available projects and ask me which one to use if the choice is ambiguous. Then claim the next ready story and work it through every required gate, recording progress, evidence, decisions and blockers in Agent Boards. Continue until no ready work remains or human input is required.";

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
  {
    eyebrow: "MCP connection",
    title: "Connect your coding agent",
    body: "Codex, Claude and other compatible agents connect to this installation through its Streamable HTTP MCP endpoint at /mcp. Once the server is configured, paste this instruction into the agent.",
    icon: IconPlugConnected,
  },
] as const;

function rememberTour() {
  try { window.localStorage.setItem(TOUR_STORAGE_KEY, "complete"); } catch { /* Storage can be disabled. */ }
}

export function FirstRunTour() {
  const [opened, setOpened] = useState(false);
  const [screen, setScreen] = useState(0);
  const [copied, setCopied] = useState(false);

  useEffect(() => {
    try { setOpened(window.localStorage.getItem(TOUR_STORAGE_KEY) !== "complete"); } catch { setOpened(true); }
    const replay = () => { setScreen(0); setOpened(true); };
    window.addEventListener("agent-boards:show-tour", replay);
    return () => window.removeEventListener("agent-boards:show-tour", replay);
  }, []);

  const current = screens[screen];
  const Icon = current.icon;
  function finish() { rememberTour(); setOpened(false); }
  async function copyAgentInstruction() {
    try {
      await navigator.clipboard.writeText(AGENT_INSTRUCTION);
    } catch {
      const field = document.createElement("textarea");
      field.value = AGENT_INSTRUCTION;
      field.style.position = "fixed";
      field.style.opacity = "0";
      document.body.append(field);
      field.select();
      document.execCommand("copy");
      field.remove();
    }
    setCopied(true);
  }

  return <Modal
    opened={opened}
    onClose={finish}
    size="lg"
    centered
    title={<span className="tour-modal-title" tabIndex={-1} data-autofocus>Welcome to Agent Boards</span>}
    classNames={{ content: "tour-modal", header: "tour-modal-header", body: "tour-modal-body" }}
  >
    <div className="tour-progress" aria-label={`Tour screen ${screen + 1} of ${screens.length}`}>
      {screens.map((entry, index) => <i key={entry.title} className={index <= screen ? "active" : ""} />)}
    </div>
    <section className="tour-screen">
      <Icon size={34} stroke={1.4} aria-hidden="true" />
      <span className="eyebrow">{current.eyebrow}</span>
      <h2>{current.title}</h2>
      <p>{current.body}</p>
      {screen === screens.length - 1 && <div className="tour-agent-command">
        <code>{AGENT_INSTRUCTION}</code>
        <Button
          leftSection={copied ? <IconCheck size={14} /> : <IconCopy size={14} />}
          onClick={copyAgentInstruction}
        >
          {copied ? "Copied" : "Copy instruction"}
        </Button>
      </div>}
    </section>
    <div className="tour-actions">
      <Button variant="subtle" onClick={finish}>Skip tour</Button>
      <div>
        {screen > 0 && <Button onClick={() => { setCopied(false); setScreen((value) => value - 1); }}>Back</Button>}
        <Button onClick={() => screen === screens.length - 1 ? finish() : setScreen((value) => value + 1)}>{screen === screens.length - 1 ? "Start using Agent Boards" : "Next"}</Button>
      </div>
    </div>
  </Modal>;
}
