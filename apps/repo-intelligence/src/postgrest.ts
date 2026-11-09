import { config } from "./config.js";

export type JsonRecord = Record<string, unknown>;

export async function rest<T = unknown>(path: string, init: RequestInit = {}): Promise<T> {
  const response = await fetch(`${config.postgrestUrl}${path}`, {
    ...init,
    headers: {
      "Content-Type": "application/json",
      Prefer: "return=representation",
      ...init.headers,
    },
  });
  if (!response.ok) {
    const detail = await response.text();
    throw new Error(`Agent Boards API ${response.status}: ${detail}`);
  }
  if (response.status === 204) return undefined as T;
  return response.json() as Promise<T>;
}

export async function insertChunks(table: string, rows: JsonRecord[], chunkSize = 500) {
  for (let index = 0; index < rows.length; index += chunkSize) {
    await rest(`/${table}`, {
      method: "POST",
      body: JSON.stringify(rows.slice(index, index + chunkSize)),
    });
  }
}
