import path from "node:path";
import { config } from "./config.js";
import { detectLanguage, extractTypeScriptIntelligence, isGeneratedPath } from "./languages.js";
import { insertChunks, JsonRecord, rest } from "./postgrest.js";
import { run } from "./process.js";
import { ensureMirror, resolveRevision } from "./repository.js";

type RepositoryRecord = {
  id: string;
  project_id: string;
  repository_url: string;
  default_branch: string;
};

type JobRecord = {
  id: string;
  project_id: string;
  repository_id: string;
  requested_revision: string | null;
  actor_name: string;
};

type TreeEntry = {
  mode: string;
  blobSha: string;
  size: number;
  path: string;
};

function parseTree(output: Buffer): TreeEntry[] {
  return output.toString("utf8").split("\0").filter(Boolean).map((entry) => {
    const tab = entry.indexOf("\t");
    const metadata = entry.slice(0, tab).split(/\s+/);
    return {
      mode: metadata[0],
      blobSha: metadata[2],
      size: Number(metadata[3]) || 0,
      path: entry.slice(tab + 1),
    };
  });
}

function qualityChecksFromPackageJson(snapshotId: string, packagePath: string, raw: string): JsonRecord[] {
  try {
    const parsed = JSON.parse(raw) as { scripts?: Record<string, string> };
    const scripts = parsed.scripts ?? {};
    const supported = ["lint", "format", "format:check", "typecheck", "type-check", "test", "test:unit", "test:integration", "build"];
    return supported.flatMap((name) => typeof scripts[name] === "string" ? [{
      snapshot_id: snapshotId,
      check_key: `${packagePath}:${name}`,
      check_kind: name.startsWith("test") ? "test" : name === "build" ? "build" : "static_analysis",
      command: `npm run ${name}`,
      source_path: packagePath,
      configuration: { script: scripts[name], discovered: true },
    }] : []);
  } catch {
    return [];
  }
}

async function createSnapshot(repository: RepositoryRecord, requestedRevision: string | null, commitSha: string) {
  const existing = await rest<JsonRecord[]>(
    `/repository_snapshots?repository_id=eq.${repository.id}&commit_sha=eq.${commitSha}&index_version=eq.${config.indexVersion}&limit=1`,
  );
  if (existing[0]?.status === "ready") return { snapshot: existing[0], reused: true };
  if (existing[0]) {
    const snapshotId = String(existing[0].id);
    await Promise.all([
      rest(`/repository_files?snapshot_id=eq.${snapshotId}`, { method: "DELETE" }),
      rest(`/repository_symbols?snapshot_id=eq.${snapshotId}`, { method: "DELETE" }),
      rest(`/repository_edges?snapshot_id=eq.${snapshotId}`, { method: "DELETE" }),
      rest(`/repository_quality_checks?snapshot_id=eq.${snapshotId}`, { method: "DELETE" }),
    ]);
    const reset = await rest<JsonRecord[]>(`/repository_snapshots?id=eq.${snapshotId}`, {
      method: "PATCH",
      body: JSON.stringify({
        requested_revision: requestedRevision,
        status: "building",
        error_message: null,
        indexed_at: null,
        file_count: 0,
        symbol_count: 0,
        edge_count: 0,
        quality_check_count: 0,
        parse_error_count: 0,
      }),
    });
    if (!reset[0]) throw new Error("Failed to reset repository snapshot.");
    return { snapshot: reset[0], reused: false };
  }
  const created = await rest<JsonRecord[]>("/repository_snapshots", {
    method: "POST",
    body: JSON.stringify({
      project_id: repository.project_id,
      repository_id: repository.id,
      requested_revision: requestedRevision,
      commit_sha: commitSha,
      index_version: config.indexVersion,
      precision: "syntax",
      status: "building",
    }),
  });
  if (!created[0]) throw new Error("Failed to create repository snapshot.");
  return { snapshot: created[0], reused: false };
}

export async function indexRepository(job: JobRecord) {
  const repositories = await rest<RepositoryRecord[]>(`/project_repositories?id=eq.${job.repository_id}&limit=1`);
  const repository = repositories[0];
  if (!repository) throw new Error("The linked repository no longer exists.");

  const mirror = await ensureMirror(job.project_id, repository.repository_url);
  const commitSha = await resolveRevision(mirror, job.requested_revision, repository.default_branch);
  const { snapshot, reused } = await createSnapshot(repository, job.requested_revision, commitSha);
  const snapshotId = String(snapshot.id);
  if (reused) return { snapshotId, commitSha, reused: true };

  try {
    const treeOutput = await run("git", ["--git-dir", mirror, "ls-tree", "-r", "-l", "-z", commitSha], {
      maxBytes: 100 * 1024 * 1024,
      timeoutMs: 120_000,
    });
    const entries = parseTree(treeOutput.stdout);
    if (entries.length > config.maxFiles) throw new Error(`Repository has ${entries.length} files; limit is ${config.maxFiles}.`);
    const totalBytes = entries.reduce((sum, entry) => sum + entry.size, 0);
    if (totalBytes > config.maxRepositoryBytes) {
      throw new Error(`Repository contains ${totalBytes} bytes; limit is ${config.maxRepositoryBytes}.`);
    }

    const files: JsonRecord[] = [];
    const symbols: JsonRecord[] = [];
    const edges: JsonRecord[] = [];
    const qualityChecks: JsonRecord[] = [];
    const languageCounts = new Map<string, number>();
    let parseErrorCount = 0;

    for (const entry of entries) {
      const language = detectLanguage(entry.path);
      const generated = isGeneratedPath(entry.path);
      languageCounts.set(language, (languageCounts.get(language) ?? 0) + 1);
      let lineCount: number | null = null;
      let content: string | null = null;
      const parsable = !generated && entry.mode !== "120000" && entry.size <= config.maxParseBytes;
      if (parsable && (language === "typescript" || language === "tsx" || language === "javascript" || path.basename(entry.path) === "package.json")) {
        const blob = await run("git", ["--git-dir", mirror, "cat-file", "blob", entry.blobSha], {
          maxBytes: config.maxParseBytes + 1,
          timeoutMs: 30_000,
        });
        content = blob.stdout.toString("utf8");
        if (!content.includes("\0")) lineCount = content.length === 0 ? 0 : content.split(/\r?\n/).length;
      }
      files.push({
        snapshot_id: snapshotId,
        path: entry.path,
        blob_sha: entry.blobSha,
        language,
        size_bytes: entry.size,
        line_count: lineCount,
        is_generated: generated,
      });
      if (content && (language === "typescript" || language === "tsx" || language === "javascript")) {
        const extracted = extractTypeScriptIntelligence(content, language);
        parseErrorCount += extracted.parseErrors;
        symbols.push(...extracted.symbols.map((symbol) => ({
          snapshot_id: snapshotId,
          path: entry.path,
          name: symbol.name,
          symbol_kind: symbol.kind,
          start_line: symbol.startLine,
          start_column: symbol.startColumn,
          end_line: symbol.endLine,
          end_column: symbol.endColumn,
          container_name: symbol.containerName,
          signature: symbol.signature,
          is_exported: symbol.exported,
          precision: "syntax",
        })));
        edges.push(...extracted.edges.map((edge) => ({
          snapshot_id: snapshotId,
          source_path: entry.path,
          edge_kind: edge.kind,
          target: edge.target,
          confidence: "deterministic_syntax",
        })));
      }
      if (content && path.basename(entry.path) === "package.json") {
        qualityChecks.push(...qualityChecksFromPackageJson(snapshotId, entry.path, content));
      }
    }

    await insertChunks("repository_files", files);
    await insertChunks("repository_symbols", symbols);
    await insertChunks("repository_edges", edges);
    await insertChunks("repository_quality_checks", qualityChecks);
    const languages = Object.fromEntries([...languageCounts.entries()].sort(([left], [right]) => left.localeCompare(right)));
    await rest(`/repository_snapshots?id=eq.${snapshotId}`, {
      method: "PATCH",
      body: JSON.stringify({
        status: "ready",
        languages,
        file_count: files.length,
        symbol_count: symbols.length,
        edge_count: edges.length,
        quality_check_count: qualityChecks.length,
        parse_error_count: parseErrorCount,
        indexed_at: new Date().toISOString(),
      }),
    });
    return { snapshotId, commitSha, reused: false };
  } catch (error) {
    await rest(`/repository_snapshots?id=eq.${snapshotId}`, {
      method: "PATCH",
      body: JSON.stringify({ status: "failed", error_message: error instanceof Error ? error.message : String(error) }),
    }).catch(() => undefined);
    throw error;
  }
}

export async function processNextJob() {
  const jobs = await rest<JobRecord[]>("/repository_index_jobs?status=eq.queued&order=created_at.asc&limit=1");
  const job = jobs[0];
  if (!job) return false;
  const claimed = await rest<JsonRecord[]>(`/repository_index_jobs?id=eq.${job.id}&status=eq.queued`, {
    method: "PATCH",
    body: JSON.stringify({ status: "running", started_at: new Date().toISOString() }),
  });
  if (!claimed[0]) return false;
  try {
    const result = await indexRepository(job);
    await rest(`/repository_index_jobs?id=eq.${job.id}`, {
      method: "PATCH",
      body: JSON.stringify({
        status: "succeeded",
        snapshot_id: result.snapshotId,
        resolved_revision: result.commitSha,
        completed_at: new Date().toISOString(),
      }),
    });
  } catch (error) {
    await rest(`/repository_index_jobs?id=eq.${job.id}`, {
      method: "PATCH",
      body: JSON.stringify({
        status: "failed",
        error_message: error instanceof Error ? error.message : String(error),
        completed_at: new Date().toISOString(),
      }),
    }).catch(() => undefined);
  }
  return true;
}
