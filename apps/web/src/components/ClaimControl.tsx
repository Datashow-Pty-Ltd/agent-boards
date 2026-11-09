import { Button, Group, Modal, Select, Stack, Text } from "@mantine/core";
import { notifications } from "@mantine/notifications";
import { useEffect, useState } from "react";
import { api } from "../api";
import type { AgentWorker, WorkItem, WorkItemClaimStatus } from "../types";

type Props = {
  item: WorkItem;
  onChanged: () => void | Promise<void>;
};

function duration(seconds: number) {
  if (seconds < 60) return `${seconds}s`;
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m`;
  return `${Math.floor(seconds / 3600)}h ${Math.floor((seconds % 3600) / 60)}m`;
}

export function ClaimControl({ item, onChanged }: Props) {
  const [status, setStatus] = useState<WorkItemClaimStatus | null>(null);
  const [workers, setWorkers] = useState<AgentWorker[]>([]);
  const [transferOpened, setTransferOpened] = useState(false);
  const [workerId, setWorkerId] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    if (item.execution_state !== "running" || !item.assignee) {
      setStatus(null);
      return undefined;
    }
    let active = true;
    void api.projectWorkers(item.project_id).then((next) => {
      if (active) setWorkers(next);
    }).catch(() => undefined);
    const load = () => void api.workItemClaimStatus(item.id).then((next) => {
      if (active) setStatus(next);
    }).catch(() => undefined);
    load();
    const timer = window.setInterval(load, 30_000);
    return () => { active = false; window.clearInterval(timer); };
  }, [item.id, item.project_id, item.execution_state, item.assignee]);

  if (!status?.active_worker) return null;

  async function transfer() {
    if (!workerId) return;
    const selectedWorker = workers.find((worker) => worker.worker_id === workerId);
    setSaving(true);
    try {
      await api.authorizeIdleClaimTakeover(item.id, workerId);
      setTransferOpened(false);
      setWorkerId(null);
      await onChanged();
      notifications.show({ title: "Idle claim transferred", message: `${item.item_key} is now claimed by @${selectedWorker?.handle ?? "registered worker"}`, color: "accent" });
    } catch (error) {
      notifications.show({ title: "Claim could not be transferred", message: error instanceof Error ? error.message : String(error), color: "alert" });
    } finally { setSaving(false); }
  }

  async function release() {
    setSaving(true);
    try {
      await api.authorizeIdleClaimRelease(item.id);
      await onChanged();
      notifications.show({ title: "Idle claim released", message: `${item.item_key} is available to workers again`, color: "accent" });
    } catch (error) {
      notifications.show({ title: "Claim could not be released", message: error instanceof Error ? error.message : String(error), color: "alert" });
    } finally { setSaving(false); }
  }

  return <section className="record-block">
    <div className="record-block-title">Active claim</div>
    <Stack gap="xs">
      <Text size="sm"><strong>{status.active_worker}</strong> · last check-in {duration(status.idle_seconds)} ago</Text>
      <Text size="xs" c="dimmed">Human takeover becomes available after {duration(status.timeout_seconds)} without a heartbeat.</Text>
      {status.takeover_eligible && <>
        <Text size="sm" c="alert">This worker is idle. A person may transfer or release the claim.</Text>
        <Group gap="xs">
          <Button size="compact-sm" onClick={() => setTransferOpened(true)}>Transfer claim</Button>
          <Button size="compact-sm" variant="outline" color="alert" loading={saving} onClick={() => void release()}>Release to queue</Button>
        </Group>
      </>}
    </Stack>
    <Modal opened={transferOpened} onClose={() => setTransferOpened(false)} title="Transfer idle claim" centered>
      <Stack>
        <Text size="sm">This records a human-authorized transfer from {status.active_worker}. The previous worker will no longer be able to move the card.</Text>
        <Select
          label="Registered worker"
          value={workerId}
          onChange={setWorkerId}
          data={workers.filter((worker) => worker.worker_id !== status.active_worker_id).map((worker) => ({
            value: worker.worker_id,
            label: `${worker.display_name} · @${worker.handle} · ${worker.client_type}`,
          }))}
          placeholder="Select an active worker"
          searchable
        />
        <Group justify="flex-end"><Button variant="subtle" onClick={() => setTransferOpened(false)}>Cancel</Button><Button loading={saving} disabled={!workerId} onClick={() => void transfer()}>Authorize transfer</Button></Group>
      </Stack>
    </Modal>
  </section>;
}
