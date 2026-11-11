import { describeSummary, externaliseInlineAssets, storeInlineMedia } from "./inlineMedia.js";
import { uploadDirectory } from "./media.js";
import { rest } from "./upstreams.js";

/**
 * Replaces inline data: URLs in an asset attachment with managed /uploads
 * URLs before the row is written. When the source is inline, its media type
 * is returned so the asset's mime_type matches the stored file. Files are
 * content-addressed and kept even if the attachment is then refused.
 */
export async function storeAttachmentMedia(sourceUrl: string, thumbnailUrl: string | undefined) {
  const source = sourceUrl.startsWith("data:") ? await storeInlineMedia(sourceUrl, uploadDirectory) : null;
  const thumbnail = thumbnailUrl?.startsWith("data:") ? await storeInlineMedia(thumbnailUrl, uploadDirectory) : null;
  return {
    sourceUrl: source?.url ?? sourceUrl,
    thumbnailUrl: thumbnail?.url ?? thumbnailUrl,
    sourceMimeType: source?.mimeType ?? null,
  };
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
