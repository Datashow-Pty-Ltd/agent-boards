import { capabilitiesForWorkPackage } from "./serviceCapabilities.js";

export type Json = Record<string, unknown> | Record<string, unknown>[];

const postgrestUrl = (process.env.POSTGREST_URL ?? "http://postgrest:3000").replace(/\/$/, "");
const repoIntelligenceUrl = (process.env.REPO_INTELLIGENCE_URL ?? "http://intelligence:8081").replace(/\/$/, "");

export async function rest(path: string, init: RequestInit = {}): Promise<Json> {
  const response = await fetch(`${postgrestUrl}${path}`, {
    ...init,
    headers: {
      "Content-Type": "application/json",
      Prefer: "return=representation",
      ...init.headers,
    },
  });
  if (!response.ok) {
    const detail = await response.text();
    throw new Error(`Board API ${response.status}: ${detail}`);
  }
  if (response.status === 204) return {};
  return response.json() as Promise<Json>;
}

export async function intelligence(path: string, init: RequestInit = {}): Promise<unknown> {
  const response = await fetch(`${repoIntelligenceUrl}${path}`, {
    ...init,
    headers: { "Content-Type": "application/json", ...init.headers },
  });
  if (!response.ok) {
    const detail = await response.text();
    throw new Error(`Repository intelligence ${response.status}: ${detail}`);
  }
  if (response.status === 204) return {};
  return response.json();
}

export function textResult(value: unknown) {
  return { content: [{ type: "text" as const, text: JSON.stringify(value, null, 2) }] };
}

export function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export async function getProjectRepository(projectId: string) {
  const repositories = await rest(`/project_repositories?project_id=eq.${projectId}&limit=1`) as Record<string, unknown>[];
  return repositories[0] ?? null;
}

export async function attachRepositoryToContext(payload: Json, projectId?: string): Promise<Json> {
  if (!isRecord(payload)) return payload;
  const workPackage = isRecord(payload.work_package) ? payload.work_package : payload;
  const story = isRecord(workPackage.story) ? workPackage.story : null;
  const resolvedProjectId = projectId ?? (typeof story?.project_id === "string" ? story.project_id : null);
  const repository = resolvedProjectId ? await getProjectRepository(resolvedProjectId) : null;
  const serviceCapabilities = capabilitiesForWorkPackage(workPackage, repository !== null);
  const enrichedWorkPackage = {
    ...workPackage,
    ...(resolvedProjectId ? { repository } : {}),
    ...(serviceCapabilities.length > 0 ? { service_capabilities: serviceCapabilities } : {}),
  };
  if (workPackage === payload) return enrichedWorkPackage;
  return { ...payload, work_package: enrichedWorkPackage };
}
