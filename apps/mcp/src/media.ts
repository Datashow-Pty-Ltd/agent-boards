import { execFile } from "node:child_process";
import { randomUUID } from "node:crypto";
import { mkdir, unlink, writeFile } from "node:fs/promises";
import path from "node:path";
import { promisify } from "node:util";
import { contentAddressedUploadFilename, managedUploadFilename, maxUploadBytes, mediaExtensions } from "./inlineMedia.js";

export const uploadDirectory = process.env.UPLOAD_DIR ?? "/data/uploads";
const execFileAsync = promisify(execFile);

export async function storeMedia(buffer: Buffer, mimeType: string, originalFilename: string) {
  const extension = mediaExtensions[mimeType];
  if (!extension) throw new Error(`Unsupported media type: ${mimeType}`);
  if (buffer.length === 0) throw new Error("The uploaded file is empty.");
  if (buffer.length > maxUploadBytes) throw new Error("Validation media must be smaller than 50 MB.");
  await mkdir(uploadDirectory, { recursive: true });
  const id = randomUUID();
  const storedFilename = `${id}.${extension}`;
  await writeFile(path.join(uploadDirectory, storedFilename), buffer, { flag: "wx" });
  return {
    id,
    url: `/uploads/${storedFilename}`,
    mimeType,
    filename: originalFilename || `validation-recording.${extension}`,
    size: buffer.length,
  };
}

export async function deleteStoredMedia(url: string) {
  const filename = url.replace(/^\/uploads\//, "");
  if (!managedUploadFilename.test(filename) || contentAddressedUploadFilename.test(filename)) return;
  await unlink(path.join(uploadDirectory, filename)).catch(() => undefined);
}

export async function probeVideoDuration(url: string) {
  const filename = url.replace(/^\/uploads\//, "");
  const { stdout } = await execFileAsync("ffprobe", [
    "-v", "error", "-show_entries", "format=duration", "-of", "default=noprint_wrappers=1:nokey=1",
    path.join(uploadDirectory, filename),
  ]);
  const durationSeconds = Number(stdout.trim());
  if (!Number.isFinite(durationSeconds) || durationSeconds <= 0) throw new Error("Could not read the validation recording duration.");
  return Math.round(durationSeconds * 100) / 100;
}
