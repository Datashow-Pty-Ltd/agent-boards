import { Button, Group, Modal, Stack, TextInput, Textarea } from "@mantine/core";
import { useState } from "react";
import { notifications } from "@mantine/notifications";
import { api } from "../api";

export function CreateProjectModal({ opened, onClose, onCreated }: { opened: boolean; onClose: () => void; onCreated: () => void }) {
  const [name, setName] = useState("");
  const [key, setKey] = useState("");
  const [description, setDescription] = useState("");
  const [owner, setOwner] = useState("");
  const [repositoryUrl, setRepositoryUrl] = useState("");
  const [defaultBranch, setDefaultBranch] = useState("main");
  const [saving, setSaving] = useState(false);
  async function create() {
    if (!name.trim() || !key.trim()) return;
    setSaving(true);
    try {
      await api.createProject({
        name: name.trim(),
        key: key.trim(),
        description: description.trim(),
        owner: owner.trim() || "Unassigned",
        repositoryUrl: repositoryUrl.trim() || undefined,
        defaultBranch: defaultBranch.trim() || "main",
      });
      notifications.show({ title: "Project created", message: `${name} now has a delivery board.`, color: "accent" });
      setName(""); setKey(""); setDescription(""); setOwner(""); setRepositoryUrl(""); setDefaultBranch("main"); onCreated(); onClose();
    } catch (error) {
      notifications.show({ title: "Could not create project", message: error instanceof Error ? error.message : String(error), color: "alert" });
    } finally { setSaving(false); }
  }
  return (
    <Modal opened={opened} onClose={onClose} title={<span className="modal-title">New project</span>} size="lg">
      <Stack gap="md">
        <Group grow align="start"><TextInput label="Project name" value={name} onChange={(e) => setName(e.currentTarget.value)} autoFocus /><TextInput label="Key" description="2–12 letters or numbers" value={key} onChange={(e) => setKey(e.currentTarget.value.toUpperCase().replace(/[^A-Z0-9-]/g, "").slice(0, 12))} /></Group>
        <Textarea label="Outcome" minRows={3} value={description} onChange={(e) => setDescription(e.currentTarget.value)} placeholder="What should be different when this project is done?" />
        <TextInput label="Owner" value={owner} onChange={(e) => setOwner(e.currentTarget.value)} />
        <Group grow align="start"><TextInput label="Repository URL" description="Optional HTTPS source repository" placeholder="https://github.com/organisation/repository" value={repositoryUrl} onChange={(e) => setRepositoryUrl(e.currentTarget.value)} /><TextInput label="Default branch" value={defaultBranch} onChange={(e) => setDefaultBranch(e.currentTarget.value)} /></Group>
        <Group justify="flex-end"><Button onClick={onClose}>Cancel</Button><Button variant="filled" color="accent" loading={saving} disabled={!name.trim() || key.length < 2} onClick={create}>Create project</Button></Group>
      </Stack>
    </Modal>
  );
}
