import path from "node:path";

export const config = {
  port: Number(process.env.PORT ?? 8081),
  postgrestUrl: (process.env.POSTGREST_URL ?? "http://postgrest:3000").replace(/\/$/, ""),
  repositoryRoot: process.env.REPOSITORY_ROOT ?? "/data/repositories",
  indexVersion: "tree-sitter-typescript-v1",
  pollMs: Number(process.env.INDEX_POLL_MS ?? 1000),
  maxFiles: Number(process.env.MAX_REPOSITORY_FILES ?? 50_000),
  maxRepositoryBytes: Number(process.env.MAX_REPOSITORY_BYTES ?? 500 * 1024 * 1024),
  maxParseBytes: Number(process.env.MAX_PARSE_BYTES ?? 1_000_000),
  maxSearchResults: Number(process.env.MAX_SEARCH_RESULTS ?? 200),
  allowedPrivateGitHosts: new Set(
    (process.env.ALLOWED_PRIVATE_GIT_HOSTS ?? "")
      .split(",")
      .map((value) => value.trim().toLowerCase())
      .filter(Boolean),
  ),
};

export function mirrorPath(projectId: string) {
  return path.join(config.repositoryRoot, "mirrors", `${projectId}.git`);
}
