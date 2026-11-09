import { execFile } from "node:child_process";
import { readFile } from "node:fs/promises";
import { promisify } from "node:util";

const run = promisify(execFile);
const patterns = [
  ["GitHub token", /\b(?:gh[opusr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})\b/g],
  ["OpenAI-style secret", /\bsk-[A-Za-z0-9_-]{20,}\b/g],
  ["AWS access key", /\bAKIA[0-9A-Z]{16}\b/g],
  ["private key", /-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/g],
];
const { stdout } = await run("git", ["ls-files", "--cached", "--others", "--exclude-standard", "-z"], { encoding: "buffer" });
const files = stdout.toString("utf8").split("\0").filter(Boolean);
const findings = [];
let scanned = 0;

for (const file of files) {
  let content;
  try {
    content = await readFile(file);
  } catch (error) {
    if (error && typeof error === "object" && "code" in error && error.code === "ENOENT") continue;
    throw error;
  }
  if (content.includes(0) || content.length > 2_000_000) continue;
  scanned += 1;
  const text = content.toString("utf8");
  for (const [label, pattern] of patterns) {
    pattern.lastIndex = 0;
    if (pattern.test(text)) findings.push(`${file}: ${label}`);
  }
}

if (findings.length) {
  throw new Error(`Potential secrets found in release-source files:\n${findings.join("\n")}`);
}
process.stdout.write(`Secret-pattern scan passed for ${scanned} tracked and untracked source files\n`);
