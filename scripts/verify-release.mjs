import { execFile } from "node:child_process";
import { access, readFile, readdir } from "node:fs/promises";
import path from "node:path";
import { promisify } from "node:util";

const run = promisify(execFile);
const root = path.resolve(".");
const publicRelease = process.argv.includes("--public");
const manifest = JSON.parse(await readFile(path.join(root, "package.json"), "utf8"));
const required = [
  "LICENSE", "NOTICE", "README.md", "CHANGELOG.md", "CONTRIBUTING.md", "SECURITY.md", "CODE_OF_CONDUCT.md",
  "AGENTS.md", "CLAUDE.md", "skills/agent-boards-worker/SKILL.md",
  "docs/security-assurance.md", "docs/certification/release-checklist.md",
  "docs/certification/security-scan-proof.md", "docs/open-source-readiness.md",
  ".github/workflows/ci.yml", ".github/workflows/release.yml", ".github/workflows/codeql.yml",
  ".github/workflows/dependency-review.yml", ".github/workflows/scorecard.yml",
  ".github/workflows/security.yml", ".github/dependabot.yml", "aqua.yaml",
  ".hadolint.yaml", ".trivyignore.yaml",
  "scripts/check-licenses.mjs", "scripts/security-oss.sh", "scripts/scan-container-images.sh",
  "compose.yaml", "docker/gateway.Containerfile", "docker/mcp.Containerfile",
  "docker/postgres.Containerfile", "docker/repo-intelligence.Containerfile", "docker/web.Containerfile",
];
await Promise.all(required.map((file) => access(path.join(root, file))));

const workflowDirectory = path.join(root, ".github/workflows");
const workflowNames = (await readdir(workflowDirectory)).filter((file) => /\.ya?ml$/.test(file));
for (const workflowName of workflowNames) {
  const workflow = await readFile(path.join(workflowDirectory, workflowName), "utf8");
  for (const line of workflow.split("\n").filter((entry) => /^\s*-?\s*uses:/.test(entry))) {
    if (!/@[0-9a-f]{40}(?:\s+#.*)?$/.test(line.trim())) {
      throw new Error(`${workflowName} contains an unpinned action: ${line.trim()}`);
    }
  }
}

const packageManifests = ["package.json", "apps/web/package.json", "apps/mcp/package.json", "apps/repo-intelligence/package.json"];
for (const filename of packageManifests) {
  const packageManifest = JSON.parse(await readFile(path.join(root, filename), "utf8"));
  if (packageManifest.license !== "Apache-2.0") {
    throw new Error(`${filename} must declare the Apache-2.0 licence`);
  }
  for (const [name, version] of Object.entries({ ...packageManifest.dependencies, ...packageManifest.devDependencies })) {
    if (!/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/.test(version)) {
      throw new Error(`${filename} must pin ${name} exactly; found ${version}`);
    }
  }
}

const migrations = (await readdir(path.join(root, "database/migrations"))).filter((file) => file.endsWith(".sql"));
const prefixes = migrations.map((file) => file.match(/^(\d+)-/)?.[1]).filter(Boolean);
const duplicatePrefixes = prefixes.filter((prefix, index) => prefixes.indexOf(prefix) !== index);
if (duplicatePrefixes.length) throw new Error(`Duplicate migration sequence numbers: ${[...new Set(duplicatePrefixes)].join(", ")}`);

const { stdout: trackedOutput } = await run("git", ["ls-files"], { cwd: root });
const tracked = trackedOutput.trim().split("\n").filter(Boolean);
const forbiddenTracked = tracked.filter((file) => /(^|\/)(node_modules|dist|artifacts|release|vendor)(\/|$)|\.tsbuildinfo$|(^|\/)\.env$/.test(file));
if (forbiddenTracked.length) throw new Error(`Generated, private, or release artifacts are tracked:\n${forbiddenTracked.join("\n")}`);

await run("docker", ["compose", "config", "--quiet"], { cwd: root });
const archive = path.join(root, "release", `agent-boards-${manifest.version}-source.tgz`);
await access(archive);
const { stdout: archiveOutput } = await run("tar", ["-tzf", archive], { cwd: root });
const archiveFiles = archiveOutput.trim().split("\n");
for (const legalFile of ["LICENSE", "NOTICE"]) {
  if (!archiveFiles.includes(legalFile)) throw new Error(`Source archive must include ${legalFile}`);
}
const forbiddenArchive = archiveFiles.filter((file) => /(^|\/)(node_modules|dist|artifacts|release|vendor)(\/|$)|\.tsbuildinfo$|(^|\/)\.env$/.test(file));
if (forbiddenArchive.length) throw new Error(`Source archive contains forbidden paths:\n${forbiddenArchive.join("\n")}`);

if (publicRelease) {
  if (manifest.license !== "Apache-2.0") throw new Error("package.json must declare Apache-2.0");
}

process.stdout.write(`Release verification passed: ${tracked.length} tracked files, ${migrations.length} ordered migrations, ${workflowNames.length} pinned workflows${publicRelease ? ", public-release requirements satisfied" : ""}\n`);
