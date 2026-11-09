import { spawn } from "node:child_process";

type RunOptions = {
  cwd?: string;
  maxBytes?: number;
  allowedExitCodes?: number[];
  timeoutMs?: number;
};

export async function run(command: string, args: string[], options: RunOptions = {}) {
  const maxBytes = options.maxBytes ?? 10 * 1024 * 1024;
  const allowedExitCodes = options.allowedExitCodes ?? [0];
  const timeoutMs = options.timeoutMs ?? 120_000;

  return new Promise<{ stdout: Buffer; stderr: Buffer; exitCode: number }>((resolve, reject) => {
    const githubToken = process.env.GITHUB_TOKEN;
    const githubAuthorization = githubToken
      ? `AUTHORIZATION: basic ${Buffer.from(`x-access-token:${githubToken}`).toString("base64")}`
      : undefined;
    const child = spawn(command, args, {
      cwd: options.cwd,
      env: {
        PATH: process.env.PATH,
        HOME: "/tmp/agent-boards-repo-intelligence",
        GIT_CONFIG_NOSYSTEM: "1",
        GIT_TERMINAL_PROMPT: "0",
        GIT_OPTIONAL_LOCKS: "0",
        ...(githubAuthorization ? {
          GIT_CONFIG_COUNT: "1",
          GIT_CONFIG_KEY_0: "http.https://github.com/.extraheader",
          GIT_CONFIG_VALUE_0: githubAuthorization,
        } : {}),
      },
      stdio: ["ignore", "pipe", "pipe"],
    });
    const stdout: Buffer[] = [];
    const stderr: Buffer[] = [];
    let outputBytes = 0;
    let settled = false;

    const timer = setTimeout(() => {
      if (settled) return;
      child.kill("SIGKILL");
      settled = true;
      reject(new Error(`${command} timed out after ${timeoutMs}ms.`));
    }, timeoutMs);

    const collect = (target: Buffer[], chunk: Buffer) => {
      outputBytes += chunk.length;
      if (outputBytes > maxBytes && !settled) {
        child.kill("SIGKILL");
        settled = true;
        clearTimeout(timer);
        reject(new Error(`${command} output exceeded ${maxBytes} bytes.`));
        return;
      }
      target.push(chunk);
    };

    child.stdout.on("data", (chunk: Buffer) => collect(stdout, chunk));
    child.stderr.on("data", (chunk: Buffer) => collect(stderr, chunk));
    child.on("error", (error) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      reject(error);
    });
    child.on("close", (exitCode) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      const code = exitCode ?? -1;
      const result = { stdout: Buffer.concat(stdout), stderr: Buffer.concat(stderr), exitCode: code };
      if (!allowedExitCodes.includes(code)) {
        reject(new Error(`${command} exited with ${code}: ${result.stderr.toString("utf8").trim()}`));
        return;
      }
      resolve(result);
    });
  });
}
