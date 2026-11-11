// Inline data: URL media is decoded into the managed uploads volume under a
// content-addressed name, so work_item_assets rows hold a short /uploads URL
// instead of megabytes of base64. Those files may be shared by several assets
// and are never deleted by request handlers, so a file can't vanish between
// being written and its row committing. This module has no relative imports so the
// contract tests can load it directly.
import { createHash, randomUUID } from "node:crypto";
import { mkdir, open, rename, stat, unlink } from "node:fs/promises";
import path from "node:path";

export const mediaExtensions: Record<string, string> = {
  "video/webm": "webm",
  "video/mp4": "mp4",
  "video/quicktime": "mov",
  "image/png": "png",
  "image/jpeg": "jpg",
  "image/webp": "webp",
  "image/gif": "gif",
};
export const maxUploadBytes = 50 * 1024 * 1024;
export const managedUploadFilename = /^[0-9a-f-]+\.(webm|mp4|mov|png|jpg|webp|gif)$/i;
/** Content-addressed uploads from inline media; several assets can share one, so request paths never delete them. */
export const contentAddressedUploadFilename = /^[0-9a-f]{64}\.[a-z0-9]+$/;

const base64Payload = /^[A-Za-z0-9+/]*={0,2}$/;

type Rest = (requestPath: string, init?: RequestInit) => Promise<unknown>;

/**
 * Decodes a base64 data: URL of a supported media type. Mirrors
 * api.inline_media_upload_url in migration 041 exactly: the URL is
 * /uploads/<sha256 of the decoded bytes>.<extension>. Returns null for
 * anything else, including payloads truncated or altered by agent tooling.
 */
export function parseInlineMedia(dataUrl: string) {
  if (!dataUrl.startsWith("data:")) return null;
  const comma = dataUrl.indexOf(",");
  if (comma < 0) return null;
  const header = dataUrl.slice(5, comma).toLowerCase();
  if (!header.endsWith(";base64")) return null;
  const mimeType = header.slice(0, -";base64".length);
  const extension = Object.hasOwn(mediaExtensions, mimeType) ? mediaExtensions[mimeType] : undefined;
  const payload = dataUrl.slice(comma + 1);
  if (!extension || !payload || payload.length % 4 !== 0 || !base64Payload.test(payload)) return null;
  const buffer = Buffer.from(payload, "base64");
  const digest = createHash("sha256").update(buffer).digest("hex");
  return { mimeType, buffer, url: `/uploads/${digest}.${extension}` };
}

/**
 * Writes inline media to the uploads volume and returns its /uploads URL.
 * The file is synced and renamed into place, so a reader never sees a partial
 * file and an existing file with the same name already holds the same bytes.
 * `created` is false when the file was already there.
 */
export async function storeInlineMedia(dataUrl: string, directory: string): Promise<{ url: string; mimeType: string; size: number; created: boolean }> {
  const media = parseInlineMedia(dataUrl);
  if (!media) {
    throw new Error(`Inline media must be a complete base64 data: URL of type ${Object.keys(mediaExtensions).join(", ")}.`);
  }
  if (media.buffer.length === 0) throw new Error("The inline media is empty.");
  if (media.buffer.length > maxUploadBytes) throw new Error("Media must be smaller than 50 MB.");
  await mkdir(directory, { recursive: true });
  const target = path.join(directory, path.basename(media.url));
  const existing = await stat(target).catch(() => null);
  if (existing?.size === media.buffer.length) return { url: media.url, mimeType: media.mimeType, size: media.buffer.length, created: false };
  const temporary = `${target}.${randomUUID()}.tmp`;
  const handle = await open(temporary, "wx");
  try {
    await handle.writeFile(media.buffer);
    await handle.sync();
  } finally {
    await handle.close();
  }
  try {
    await rename(temporary, target);
  } catch (error) {
    await unlink(temporary).catch(() => undefined);
    throw error;
  }
  return { url: media.url, mimeType: media.mimeType, size: media.buffer.length, created: !existing };
}

export type ExternaliseSummary = { candidates: number; converted: number; unchanged: number; undecodable: string[]; failed: string[]; bytesMoved: number };

/**
 * Moves existing inline data: URL media out of work_item_assets into the
 * uploads volume. Idempotent: converted rows no longer match, and the RPC
 * accepts only the URL derived from the row's own bytes. Rows are read one at
 * a time so memory stays bounded by the largest single asset.
 */
export async function externaliseInlineAssets({ rest, directory, log = () => undefined }: { rest: Rest; directory: string; log?: (message: string) => void }): Promise<ExternaliseSummary> {
  const inline = encodeURIComponent(`(source_url.like."data:*",thumbnail_url.like."data:*")`);
  const candidates = await rest(`/work_item_assets?select=id&order=created_at.asc,id.asc&or=${inline}`) as Array<{ id: string }>;
  const summary: ExternaliseSummary = { candidates: candidates.length, converted: 0, unchanged: 0, undecodable: [], failed: [], bytesMoved: 0 };
  for (const { id } of candidates) {
    try {
      const [asset] = await rest(`/work_item_assets?id=eq.${id}&select=id,source_url,thumbnail_url`) as Array<{ id: string; source_url: string; thumbnail_url: string | null }>;
      if (!asset) continue;
      const fields = [asset.source_url, asset.thumbnail_url].map((value) => value?.startsWith("data:") ? value : null);
      const decodable = fields.map((value) => value !== null && parseInlineMedia(value) !== null);
      if (fields.some((value, index) => value !== null && !decodable[index])) summary.undecodable.push(id);
      if (!decodable.some(Boolean)) {
        summary.unchanged += 1;
        continue;
      }
      const stored = await Promise.all(fields.map((value, index) => decodable[index] ? storeInlineMedia(value!, directory) : null));
      await rest("/rpc/externalise_inline_work_item_asset_media", {
        method: "POST",
        body: JSON.stringify({ target_asset_id: id, expected_source_url: stored[0]?.url ?? null, expected_thumbnail_url: stored[1]?.url ?? null }),
      });
      summary.converted += 1;
      summary.bytesMoved += fields.reduce((total, value, index) => total + (decodable[index] ? value!.length : 0), 0);
    } catch (error) {
      summary.failed.push(id);
      log(`Could not externalise inline media for asset ${id}: ${error instanceof Error ? error.message : String(error)}`);
    }
  }
  return summary;
}

export function describeSummary(summary: ExternaliseSummary) {
  const undecodable = summary.undecodable.length ? ` ${summary.undecodable.length} have undecodable inline media left in place (${summary.undecodable.join(", ")}).` : "";
  const failed = summary.failed.length ? ` ${summary.failed.length} failed (${summary.failed.join(", ")}).` : "";
  return `Inline asset media: ${summary.converted} of ${summary.candidates} assets moved to uploads (${(summary.bytesMoved / 1024 / 1024).toFixed(1)} MB of data: URLs).${undecodable}${failed}`;
}
