import express from "express";
import { mkdir } from "node:fs/promises";
import { z } from "zod";
import { config, mirrorPath } from "./config.js";
import { processNextJob } from "./indexer.js";
import { JsonRecord, rest } from "./postgrest.js";
import { run } from "./process.js";
import { resolveRevision } from "./repository.js";

const app = express();
app.use(express.json({ limit: "2mb" }));

const uuidSchema = z.string().uuid();
const revisionSchema = z.string().min(1).max(240).regex(/^[A-Za-z0-9._/@:+-]+$/);
const indexRequestSchema = z.object({
  projectId: uuidSchema,
  revision: revisionSchema.optional(),
  actor: z.string().min(1).max(120).default("AI agent"),
});
const searchSchema = z.object({
  projectId: uuidSchema,
  revision: revisionSchema.optional(),
  query: z.string().min(1).max(500),
  regex: z.boolean().default(false),
  maxResults: z.number().int().min(1).max(config.maxSearchResults).default(50),
});
const compareSchema = z.object({
  projectId: uuidSchema,
  baseRevision: revisionSchema,
  headRevision: revisionSchema,
});
const mapSchema = z.object({
  revision: revisionSchema.optional(),
  mapType: z.enum(["architecture", "domain", "dependency", "quality", "change_impact"]),
  title: z.string().min(1).max(240),
  content: z.record(z.string(), z.unknown()),
  citations: z.array(z.object({
    path: z.string().min(1).max(2000),
    startLine: z.number().int().positive().optional(),
    endLine: z.number().int().positive().optional(),
    symbol: z.string().max(500).optional(),
  })).max(1000),
  actor: z.string().min(1).max(120).default("AI agent"),
});

function encode(value: string) {
  return encodeURIComponent(value);
}

async function projectRepository(projectId: string) {
  const rows = await rest<JsonRecord[]>(`/project_repositories?project_id=eq.${projectId}&limit=1`);
  if (!rows[0]) throw new Error("The project does not have a linked repository.");
  return rows[0];
}

async function resolveSnapshot(projectId: string, revision?: string) {
  const filter = revision
    ? `&or=(commit_sha.eq.${encode(revision)},requested_revision.eq.${encode(revision)})`
    : "";
  const rows = await rest<JsonRecord[]>(
    `/repository_snapshots?project_id=eq.${projectId}&status=eq.ready${filter}&order=indexed_at.desc&limit=1`,
  );
  if (!rows[0]) throw new Error(`No ready repository snapshot exists${revision ? ` for ${revision}` : ""}.`);
  return rows[0];
}

function asyncRoute(
  handler: (request: express.Request, response: express.Response) => Promise<void>,
) {
  return (request: express.Request, response: express.Response, next: express.NextFunction) => {
    handler(request, response).catch(next);
  };
}

app.get("/health", asyncRoute(async (_request, response) => {
  await rest("/projects?select=id&limit=1");
  response.json({ ok: true, service: "agent-boards-repo-intelligence", indexVersion: config.indexVersion });
}));

app.post("/v1/index", asyncRoute(async (request, response) => {
  const input = indexRequestSchema.parse(request.body);
  await projectRepository(input.projectId);
  const jobs = await rest<JsonRecord[]>("/rpc/enqueue_repository_index", {
    method: "POST",
    body: JSON.stringify({
      target_project_id: input.projectId,
      target_revision: input.revision ?? null,
      actor_name: input.actor,
    }),
  });
  response.status(202).json(jobs[0] ?? jobs);
}));

app.get("/v1/jobs/:jobId", asyncRoute(async (request, response) => {
  const jobId = uuidSchema.parse(request.params.jobId);
  const rows = await rest<JsonRecord[]>(`/repository_index_jobs?id=eq.${jobId}&limit=1`);
  if (!rows[0]) { response.status(404).json({ error: "Index job not found." }); return; }
  response.json(rows[0]);
}));

app.get("/v1/projects/:projectId/snapshots", asyncRoute(async (request, response) => {
  const projectId = uuidSchema.parse(request.params.projectId);
  const rows = await rest<JsonRecord[]>(`/repository_snapshots?project_id=eq.${projectId}&order=created_at.desc`);
  response.json(rows);
}));

app.get("/v1/projects/:projectId/snapshot", asyncRoute(async (request, response) => {
  const projectId = uuidSchema.parse(request.params.projectId);
  const revision = typeof request.query.revision === "string" ? revisionSchema.parse(request.query.revision) : undefined;
  response.json(await resolveSnapshot(projectId, revision));
}));

app.get("/v1/snapshots/:snapshotId/symbols", asyncRoute(async (request, response) => {
  const snapshotId = uuidSchema.parse(request.params.snapshotId);
  const query = typeof request.query.query === "string" ? request.query.query.slice(0, 240) : "";
  const filePath = typeof request.query.path === "string" ? request.query.path.slice(0, 2000) : "";
  const limit = Math.min(Math.max(Number(request.query.limit ?? 100), 1), 500);
  const filters = [
    `snapshot_id=eq.${snapshotId}`,
    query ? `name=ilike.*${encode(query)}*` : "",
    filePath ? `path=eq.${encode(filePath)}` : "",
  ].filter(Boolean).join("&");
  response.json(await rest(`/repository_symbols?${filters}&order=path.asc,start_line.asc&limit=${limit}`));
}));

app.get("/v1/snapshots/:snapshotId/graph", asyncRoute(async (request, response) => {
  const snapshotId = uuidSchema.parse(request.params.snapshotId);
  const filePath = typeof request.query.path === "string" ? request.query.path.slice(0, 2000) : "";
  const pathFilter = filePath ? `&source_path=eq.${encode(filePath)}` : "";
  const [snapshot, edges] = await Promise.all([
    rest<JsonRecord[]>(`/repository_snapshots?id=eq.${snapshotId}&limit=1`),
    rest(`/repository_edges?snapshot_id=eq.${snapshotId}${pathFilter}&order=source_path.asc&limit=2000`),
  ]);
  if (!snapshot[0]) { response.status(404).json({ error: "Snapshot not found." }); return; }
  response.json({ snapshot: snapshot[0], edges });
}));

app.get("/v1/snapshots/:snapshotId/quality-checks", asyncRoute(async (request, response) => {
  const snapshotId = uuidSchema.parse(request.params.snapshotId);
  response.json(await rest(`/repository_quality_checks?snapshot_id=eq.${snapshotId}&order=source_path.asc,check_key.asc`));
}));

app.get("/v1/snapshots/:snapshotId/file", asyncRoute(async (request, response) => {
  const snapshotId = uuidSchema.parse(request.params.snapshotId);
  const filePath = z.string().min(1).max(2000).parse(request.query.path);
  const snapshots = await rest<JsonRecord[]>(`/repository_snapshots?id=eq.${snapshotId}&status=eq.ready&limit=1`);
  const snapshot = snapshots[0];
  if (!snapshot) { response.status(404).json({ error: "Snapshot not found." }); return; }
  const files = await rest<JsonRecord[]>(`/repository_files?snapshot_id=eq.${snapshotId}&path=eq.${encode(filePath)}&limit=1`);
  const file = files[0];
  if (!file) { response.status(404).json({ error: "File not found in the snapshot." }); return; }
  const size = Number(file.size_bytes ?? 0);
  if (size > config.maxParseBytes) { response.status(413).json({ error: "File is too large to return." }); return; }
  const content = await run("git", ["--git-dir", mirrorPath(String(snapshot.project_id)), "cat-file", "blob", String(file.blob_sha)], {
    maxBytes: config.maxParseBytes + 1,
    timeoutMs: 30_000,
  });
  response.json({ snapshotId, commitSha: snapshot.commit_sha, file, content: content.stdout.toString("utf8") });
}));

app.post("/v1/search", asyncRoute(async (request, response) => {
  const input = searchSchema.parse(request.body);
  const snapshot = await resolveSnapshot(input.projectId, input.revision);
  const args = ["--git-dir", mirrorPath(input.projectId), "grep", "--line-number", "--column", "-I"];
  if (!input.regex) args.push("--fixed-strings");
  args.push("-e", input.query, String(snapshot.commit_sha), "--");
  const result = await run("git", args, { allowedExitCodes: [0, 1], maxBytes: 5 * 1024 * 1024, timeoutMs: 30_000 });
  const matches = result.stdout.toString("utf8").split(/\r?\n/).filter(Boolean).slice(0, input.maxResults).map((line) => {
    const match = line.match(/^[^:]+:(.*?):(\d+):(\d+):(.*)$/);
    return match ? { path: match[1], line: Number(match[2]), column: Number(match[3]), preview: match[4] } : { raw: line };
  });
  response.json({ snapshot, query: input.query, regex: input.regex, matches, truncated: matches.length >= input.maxResults });
}));

app.post("/v1/compare", asyncRoute(async (request, response) => {
  const input = compareSchema.parse(request.body);
  const repository = await projectRepository(input.projectId);
  const mirror = mirrorPath(input.projectId);
  const baseCommit = await resolveRevision(mirror, input.baseRevision, String(repository.default_branch));
  const headCommit = await resolveRevision(mirror, input.headRevision, String(repository.default_branch));
  const [names, stat] = await Promise.all([
    run("git", ["--git-dir", mirror, "diff", "--name-status", "-M", baseCommit, headCommit], { maxBytes: 10 * 1024 * 1024 }),
    run("git", ["--git-dir", mirror, "diff", "--stat", baseCommit, headCommit], { maxBytes: 5 * 1024 * 1024 }),
  ]);
  const changes = names.stdout.toString("utf8").split(/\r?\n/).filter(Boolean).map((line) => {
    const [status, ...paths] = line.split("\t");
    return { status, paths };
  });
  response.json({ projectId: input.projectId, baseCommit, headCommit, changes, stat: stat.stdout.toString("utf8") });
}));

app.get("/v1/projects/:projectId/maps", asyncRoute(async (request, response) => {
  const projectId = uuidSchema.parse(request.params.projectId);
  const revision = typeof request.query.revision === "string" ? revisionSchema.parse(request.query.revision) : undefined;
  const snapshot = await resolveSnapshot(projectId, revision);
  response.json(await rest(`/repository_maps?project_id=eq.${projectId}&snapshot_id=eq.${snapshot.id}&order=updated_at.desc`));
}));

app.put("/v1/projects/:projectId/maps/:mapKey", asyncRoute(async (request, response) => {
  const projectId = uuidSchema.parse(request.params.projectId);
  const mapKey = z.string().min(1).max(120).regex(/^[a-z0-9]+(?:-[a-z0-9]+)*$/).parse(request.params.mapKey);
  const input = mapSchema.parse(request.body);
  const snapshot = await resolveSnapshot(projectId, input.revision);
  const result = await rest("/rpc/upsert_repository_map", {
    method: "POST",
    body: JSON.stringify({
      target_project_id: projectId,
      target_snapshot_id: snapshot.id,
      target_map_key: mapKey,
      target_map_type: input.mapType,
      map_title: input.title,
      map_content: input.content,
      map_citations: input.citations.map((citation) => ({
        path: citation.path,
        start_line: citation.startLine ?? null,
        end_line: citation.endLine ?? null,
        symbol: citation.symbol ?? null,
      })),
      actor_name: input.actor,
    }),
  });
  response.json(result);
}));

app.use((error: unknown, _request: express.Request, response: express.Response, _next: express.NextFunction) => {
  void _next;
  const status = error instanceof z.ZodError ? 400 : 500;
  response.status(status).json({ error: error instanceof Error ? error.message : String(error) });
});

await mkdir(config.repositoryRoot, { recursive: true });
let workerBusy = false;
const poll = async () => {
  if (workerBusy) return;
  workerBusy = true;
  try {
    while (await processNextJob()) { /* drain the durable queue */ }
  } catch (error) {
    console.error("Repository intelligence worker error", error);
  } finally {
    workerBusy = false;
  }
};
setInterval(() => void poll(), config.pollMs);
void poll();

app.listen(config.port, "0.0.0.0", () => {
  console.log(`Agent Boards repository intelligence listening on ${config.port}`);
});
