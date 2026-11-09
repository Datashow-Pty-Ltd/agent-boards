import { ActionIcon, Button, Group, Modal, TextInput } from "@mantine/core";
import { notifications } from "@mantine/notifications";
import { IconEdit, IconPlus, IconTrash } from "@tabler/icons-react";
import { useEffect, useMemo, useState } from "react";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
import { api } from "../api";
import type { ProjectArtifact } from "../types";

type RegisterDocument = {
  prefix: string;
  headers: string[];
  rows: string[][];
  suffix: string;
};

const registerTypes = new Set(["risk_register", "issue_register"]);

const registerHeaders: Record<string, string[]> = {
  risk_register: ["ID", "Risk", "Likelihood", "Impact", "Mitigation", "Owner", "Status"],
  issue_register: ["ID", "Issue", "Priority", "Owner", "Status", "Resolution"],
};

function splitTableRow(line: string) {
  return line.trim().replace(/^\|/, "").replace(/\|$/, "").split(/(?<!\\)\|/).map((cell) => cell.trim().replace(/\\\|/g, "|"));
}

function isDivider(line: string) {
  return splitTableRow(line).every((cell) => /^:?-{3,}:?$/.test(cell));
}

function parseRegisterDocument(content: string, type: string): RegisterDocument {
  const lines = content.replace(/\r\n/g, "\n").split("\n");
  const start = lines.findIndex((line, index) => line.includes("|") && index + 1 < lines.length && isDivider(lines[index + 1]));
  const defaults = registerHeaders[type] ?? ["ID", "Record", "Owner", "Status"];
  if (start < 0) {
    const bulletRows = lines.flatMap((line) => {
      const match = line.match(/^\s*(?:[-*+]|\d+[.)])\s+(.+)$/);
      return match ? [match[1].trim()] : [];
    });
    if (bulletRows.length) {
      const prefix = type === "risk_register" ? "R" : type === "issue_register" ? "I" : "ITEM";
      const prose = lines.filter((line) => !/^\s*(?:[-*+]|\d+[.)])\s+/.test(line) && !/^#{1,6}\s+(risks?|issues?)\s*$/i.test(line)).join("\n").trim();
      return {
        prefix: prose,
        headers: defaults,
        rows: bulletRows.map((value, index) => defaults.map((_, cellIndex) => cellIndex === 0 ? `${prefix}-${String(index + 1).padStart(3, "0")}` : cellIndex === 1 ? value : "")),
        suffix: "",
      };
    }
    return { prefix: content.trim(), headers: defaults, rows: [], suffix: "" };
  }

  let end = start + 2;
  while (end < lines.length && lines[end].includes("|")) end += 1;
  const headers = splitTableRow(lines[start]);
  const rows = lines.slice(start + 2, end).filter((line) => line.trim()).map((line) => {
    const cells = splitTableRow(line);
    return headers.map((_, index) => cells[index] ?? "");
  });
  return {
    prefix: lines.slice(0, start).join("\n").trim(),
    headers,
    rows,
    suffix: lines.slice(end).join("\n").trim(),
  };
}

function escapeTableCell(value: string) {
  return value.replace(/\r?\n/g, " ").replace(/\|/g, "\\|").trim();
}

function serializeRegisterDocument(document: RegisterDocument) {
  const table = [
    `| ${document.headers.map(escapeTableCell).join(" | ")} |`,
    `| ${document.headers.map(() => "---").join(" | ")} |`,
    ...document.rows.map((row) => `| ${document.headers.map((_, index) => escapeTableCell(row[index] ?? "")).join(" | ")} |`),
  ].join("\n");
  return [document.prefix, table, document.suffix].filter(Boolean).join("\n\n");
}

function displayContent(record: ProjectArtifact) {
  if (record.content.trim()) return record.content;
  if (registerTypes.has(record.artifact_type)) return serializeRegisterDocument(parseRegisterDocument("", record.artifact_type));
  return `_${record.description || "No content has been recorded yet."}_`;
}

function RegisterEditor({ document, onChange }: { document: RegisterDocument; onChange: (next: RegisterDocument) => void }) {
  const keyPrefix = document.headers.some((header) => header.toLowerCase() === "issue") ? "I" : "R";
  function addRow() {
    const nextId = `${keyPrefix}-${String(document.rows.length + 1).padStart(3, "0")}`;
    onChange({ ...document, rows: [...document.rows, document.headers.map((_, index) => index === 0 ? nextId : "")] });
  }
  function updateCell(rowIndex: number, cellIndex: number, value: string) {
    onChange({ ...document, rows: document.rows.map((row, index) => index === rowIndex ? row.map((cell, position) => position === cellIndex ? value : cell) : row) });
  }
  function removeRow(rowIndex: number) {
    onChange({ ...document, rows: document.rows.filter((_, index) => index !== rowIndex) });
  }

  return <div className="project-register-editor">
    <div className="project-register-table-wrap">
      <table>
        <thead><tr>{document.headers.map((header) => <th key={header}>{header}</th>)}<th><span className="visually-hidden">Actions</span></th></tr></thead>
        <tbody>{document.rows.map((row, rowIndex) => <tr key={`${row[0] || "row"}-${rowIndex}`}>
          {document.headers.map((header, cellIndex) => <td key={`${header}-${cellIndex}`}><TextInput aria-label={`${header}, row ${rowIndex + 1}`} value={row[cellIndex] ?? ""} onChange={(event) => updateCell(rowIndex, cellIndex, event.currentTarget.value)} /></td>)}
          <td><ActionIcon variant="subtle" color="alert" aria-label={`Delete row ${rowIndex + 1}`} onClick={() => removeRow(rowIndex)}><IconTrash size={16} /></ActionIcon></td>
        </tr>)}</tbody>
      </table>
      {!document.rows.length && <div className="project-register-empty">No records yet. Add the first record to this register.</div>}
    </div>
    <Button variant="subtle" color="dark" leftSection={<IconPlus size={15} />} onClick={addRow}>Add record</Button>
  </div>;
}

export function ProjectDocumentModal({ record, onClose, onUpdated }: { record: ProjectArtifact | null; onClose: () => void; onUpdated: (record: ProjectArtifact) => void }) {
  const isRegister = Boolean(record && registerTypes.has(record.artifact_type));
  const isDesignConcept = record?.artifact_type === "design_concept";
  const isDesignSystem = record?.artifact_type === "design_system";
  const [editing, setEditing] = useState(false);
  const [saving, setSaving] = useState(false);
  const [registerDocument, setRegisterDocument] = useState<RegisterDocument | null>(null);
  const content = record ? displayContent(record) : "";
  const renderedContent = record && isRegister ? serializeRegisterDocument(parseRegisterDocument(content, record.artifact_type)) : content;
  const updatedLabel = useMemo(() => record ? new Intl.DateTimeFormat("en-AU", { day: "numeric", month: "short", year: "numeric", timeZone: "UTC" }).format(new Date(record.updated_at)) : "", [record]);

  useEffect(() => {
    setEditing(false);
    setRegisterDocument(record && registerTypes.has(record.artifact_type) ? parseRegisterDocument(displayContent(record), record.artifact_type) : null);
  }, [record]);

  async function saveRegister() {
    if (!record || !registerDocument) return;
    setSaving(true);
    try {
      const result = await api.saveProjectArtifact(record, serializeRegisterDocument(registerDocument));
      const updated = result[0];
      if (updated) {
        onUpdated(updated);
        setRegisterDocument(parseRegisterDocument(displayContent(updated), updated.artifact_type));
      }
      setEditing(false);
      notifications.show({ title: `${record.title} updated`, message: "The Markdown register was versioned and saved.", color: "accent" });
    } catch (error) {
      notifications.show({ title: "Could not save register", message: error instanceof Error ? error.message : String(error), color: "alert" });
    } finally {
      setSaving(false);
    }
  }

  async function approveDesignRecord() {
    if (!record) return;
    setSaving(true);
    try {
      const result = isDesignConcept
        ? await api.approveDesignConcept(record.project_id)
        : await api.approveDesignSystem(record.project_id);
      if (result[0]) onUpdated(result[0]);
      notifications.show({
        title: isDesignConcept ? "Design concept approved" : "Design system approved",
        message: isDesignConcept ? "The selected visual direction is now governed." : "Screen mockups can now be approved against this system.",
        color: "accent",
      });
    } catch (error) {
      notifications.show({ title: "Approval blocked", message: error instanceof Error ? error.message : String(error), color: "alert" });
    } finally {
      setSaving(false);
    }
  }

  return <Modal
    opened={Boolean(record)}
    onClose={onClose}
    centered
    size="min(980px, calc(100vw - 40px))"
    overlayProps={{ backgroundOpacity: 0.58, blur: 1 }}
    classNames={{ content: "project-document-modal", header: "project-document-modal-header", body: "project-document-modal-body", title: "project-document-modal-title" }}
    title={record ? <div className="project-document-title" tabIndex={-1} data-autofocus><span>{record.artifact_type.replaceAll("_", " ")} · V{record.version}</span><h2>{record.title}</h2></div> : null}
  >
    {record && <>
      <div className="project-document-meta">
        <span>{record.status}</span><span>Updated {updatedLabel} UTC</span><span>By {record.created_by}</span>
        {isRegister && !editing && <Button variant="subtle" color="dark" leftSection={<IconEdit size={15} />} onClick={() => setEditing(true)}>Edit register</Button>}
        {(isDesignConcept || isDesignSystem) && record.metadata.approved !== true && <Button variant="subtle" color="dark" loading={saving} onClick={() => void approveDesignRecord()}>{isDesignConcept ? "Approve design concept" : "Approve design system"}</Button>}
        {(isDesignConcept || isDesignSystem) && record.metadata.approved === true && <strong>Approved</strong>}
      </div>
      <div className="project-document-scroll">
        {editing && registerDocument
          ? <RegisterEditor document={registerDocument} onChange={setRegisterDocument} />
          : <article className="project-markdown"><ReactMarkdown remarkPlugins={[remarkGfm]}>{renderedContent}</ReactMarkdown></article>}
      </div>
      {editing && <div className="project-document-actions"><Group justify="flex-end"><Button variant="default" onClick={() => { setEditing(false); setRegisterDocument(parseRegisterDocument(content, record.artifact_type)); }}>Cancel</Button><Button color="dark" loading={saving} onClick={() => void saveRegister()}>Save changes</Button></Group></div>}
    </>}
  </Modal>;
}
