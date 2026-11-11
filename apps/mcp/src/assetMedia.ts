import { describeSummary, externaliseInlineAssets, removeUnreferencedUpload, storeInlineMedia } from "./inlineMedia.js";
import { uploadDirectory } from "./media.js";
import { rest } from "./upstreams.js";

/**
 * Replaces inline data: URLs in an asset attachment with managed /uploads
 * URLs before the row is written. `discard` removes files this call created
 * if the attachment is then refused, unless another asset uses them.
 */
export async function storeAttachmentMedia(sourceUrl: string, thumbnailUrl: string | undefined) {
  const created: string[] = [];
  const resolve = async (value: string) => {
    if (!value.startsWith("data:")) return value;
    const stored = await storeInlineMedia(value, uploadDirectory);
    if (stored.created) created.push(stored.url);
    return stored.url;
  };
  try {
    return {
      sourceUrl: await resolve(sourceUrl),
      thumbnailUrl: thumbnailUrl === undefined ? undefined : await resolve(thumbnailUrl),
      discard: () => discardUploads(created),
    };
  } catch (error) {
    await discardUploads(created);
    throw error;
  }
}

async function discardUploads(urls: string[]) {
  await Promise.all(urls.map((url) => removeUnreferencedUpload(rest, url, uploadDirectory).catch(() => false)));
}

const startupAttempts = 5;
const startupRetryMs = 15_000;

/**
 * Moves existing inline asset media into uploads once the board API is
 * reachable. Runs in the background on every start; after the first
 * successful pass it finds nothing to do.
 */
export function startInlineAssetExternalisation() {
  const run = async (attempt: number): Promise<void> => {
    try {
      const summary = await externaliseInlineAssets({ rest, directory: uploadDirectory, log: (message) => console.warn(message) });
      if (summary.candidates > 0) console.log(describeSummary(summary));
    } catch (error) {
      if (attempt >= startupAttempts) {
        console.warn(`Inline asset media was not externalised: ${error instanceof Error ? error.message : String(error)}`);
        return;
      }
      await new Promise((resolve) => setTimeout(resolve, startupRetryMs));
      await run(attempt + 1);
    }
  };
  void run(1);
}
