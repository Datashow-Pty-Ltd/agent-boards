import { Button, Group, Modal, Text } from "@mantine/core";
import type { ProjectSummary } from "../types";

export function ProjectArchiveModal({
  project,
  opened,
  restoring = false,
  saving,
  onClose,
  onConfirm,
}: {
  project: ProjectSummary | null;
  opened: boolean;
  restoring?: boolean;
  saving: boolean;
  onClose: () => void;
  onConfirm: () => void;
}) {
  const action = restoring ? "Restore" : "Archive";
  return <Modal
    opened={opened}
    onClose={onClose}
    title={<span className="modal-title">{action} project</span>}
    size="md"
  >
    <Text size="sm">
      {restoring
        ? <>Restore <strong>{project?.name}</strong> to the active portfolio and allow work to continue?</>
        : <>Archive <strong>{project?.name}</strong>? Its board and project record will be preserved, hidden from the active portfolio, and its work queue will be made read-only until restored.</>}
    </Text>
    <Group justify="flex-end" mt="xl">
      <Button variant="subtle" color="dark" onClick={onClose} disabled={saving}>Cancel</Button>
      <Button color={restoring ? "accent" : "alert"} onClick={onConfirm} loading={saving}>{action} project</Button>
    </Group>
  </Modal>;
}
