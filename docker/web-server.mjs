import { createReadStream } from "node:fs";
import { access, stat } from "node:fs/promises";
import { createServer } from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), "dist");
const port = Number(process.env.PORT ?? 5173);
const contentTypes = new Map([
  [".css", "text/css; charset=utf-8"],
  [".html", "text/html; charset=utf-8"],
  [".ico", "image/x-icon"],
  [".js", "text/javascript; charset=utf-8"],
  [".json", "application/json; charset=utf-8"],
  [".svg", "image/svg+xml"],
  [".woff", "font/woff"],
  [".woff2", "font/woff2"],
]);

async function resolveFile(urlPath) {
  const decoded = decodeURIComponent(urlPath);
  const candidate = path.resolve(root, `.${decoded}`);
  if (candidate !== root && !candidate.startsWith(`${root}${path.sep}`)) return null;
  try {
    if ((await stat(candidate)).isFile()) return candidate;
  } catch {
    // Client-side routes deliberately fall through to the application shell.
  }
  return path.join(root, "index.html");
}

const server = createServer(async (request, response) => {
  try {
    const requestUrl = new URL(request.url ?? "/", "http://localhost");
    if (requestUrl.pathname === "/health") {
      response.writeHead(200, { "content-type": "application/json; charset=utf-8" });
      response.end('{"ok":true,"service":"agent-boards-web"}');
      return;
    }
    const file = await resolveFile(requestUrl.pathname);
    if (!file) {
      response.writeHead(400);
      response.end("Bad request");
      return;
    }
    await access(file);
    const extension = path.extname(file);
    const immutable = requestUrl.pathname.startsWith("/assets/");
    response.writeHead(200, {
      "cache-control": immutable ? "public, max-age=31536000, immutable" : "no-cache",
      "content-type": contentTypes.get(extension) ?? "application/octet-stream",
      "x-content-type-options": "nosniff",
    });
    if (request.method === "HEAD") response.end();
    else createReadStream(file).pipe(response);
  } catch (error) {
    response.writeHead(500, { "content-type": "text/plain; charset=utf-8" });
    response.end(error instanceof Error ? error.message : "Internal server error");
  }
});

server.listen(port, "0.0.0.0", () => {
  process.stdout.write(`Agent Boards web listening on ${port}\n`);
});
