// One-off command that moves inline data: URL asset media into the uploads
// volume. The MCP server also runs this on start; use the command to run it
// on demand and see the result, for example:
//   container exec agent-boards-mcp node dist/externaliseInlineAssets.js
//   docker compose exec mcp node dist/externaliseInlineAssets.js
import { describeSummary, externaliseInlineAssets } from "./inlineMedia.js";
import { uploadDirectory } from "./media.js";
import { rest } from "./upstreams.js";

const summary = await externaliseInlineAssets({ rest, directory: uploadDirectory, log: (message) => console.error(message) });
console.log(describeSummary(summary));
if (summary.failed.length) process.exitCode = 1;
