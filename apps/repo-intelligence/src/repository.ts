import { lookup } from "node:dns/promises";
import { mkdir, rm } from "node:fs/promises";
import net from "node:net";
import path from "node:path";
import { config, mirrorPath } from "./config.js";
import { run } from "./process.js";

function isPrivateAddress(address: string) {
  if (net.isIPv4(address)) {
    const [a, b] = address.split(".").map(Number);
    return a === 10
      || a === 127
      || (a === 169 && b === 254)
      || (a === 172 && b >= 16 && b <= 31)
      || (a === 192 && b === 168)
      || a === 0;
  }
  const normalized = address.toLowerCase();
  return normalized === "::1" || normalized.startsWith("fc") || normalized.startsWith("fd") || normalized.startsWith("fe80:");
}

export async function validateRepositoryUrl(repositoryUrl: string) {
  const parsed = new URL(repositoryUrl);
  if (parsed.protocol !== "https:") throw new Error("Repository intelligence accepts HTTPS repositories only.");
  if (parsed.username || parsed.password) throw new Error("Repository credentials must not be embedded in the repository URL.");
  const host = parsed.hostname.toLowerCase();
  if (!config.allowedPrivateGitHosts.has(host)) {
    const addresses = await lookup(host, { all: true });
    if (addresses.some(({ address }) => isPrivateAddress(address))) {
      throw new Error(`Repository host ${host} resolves to a private address and is not allow-listed.`);
    }
  }
  return parsed.toString().replace(/\/$/, "");
}

export async function ensureMirror(projectId: string, repositoryUrl: string) {
  const safeUrl = await validateRepositoryUrl(repositoryUrl);
  const target = mirrorPath(projectId);
  await mkdir(path.dirname(target), { recursive: true });
  try {
    await run("git", ["--git-dir", target, "rev-parse", "--is-bare-repository"], { timeoutMs: 10_000 });
    await run("git", ["--git-dir", target, "remote", "set-url", "origin", safeUrl], { timeoutMs: 10_000 });
    await run("git", ["--git-dir", target, "fetch", "--prune", "--tags", "origin"], { timeoutMs: 300_000 });
  } catch {
    await rm(target, { recursive: true, force: true });
    await run("git", ["clone", "--mirror", safeUrl, target], { timeoutMs: 300_000, maxBytes: 20 * 1024 * 1024 });
  }
  return target;
}

export async function resolveRevision(mirror: string, requestedRevision: string | null, defaultBranch: string) {
  const candidates = requestedRevision
    ? [requestedRevision]
    : [`refs/heads/${defaultBranch}`, `refs/remotes/origin/${defaultBranch}`, defaultBranch, "HEAD"];
  for (const candidate of candidates) {
    const result = await run("git", ["--git-dir", mirror, "rev-parse", "--verify", `${candidate}^{commit}`], {
      allowedExitCodes: [0, 128],
      timeoutMs: 15_000,
    });
    if (result.exitCode === 0) return result.stdout.toString("utf8").trim();
  }
  throw new Error(`Cannot resolve revision ${requestedRevision ?? defaultBranch}.`);
}

export async function gitShowBlob(mirror: string, blobSha: string, maxBytes: number) {
  return (await run("git", ["--git-dir", mirror, "cat-file", "blob", blobSha], {
    maxBytes,
    timeoutMs: 30_000,
  })).stdout;
}
