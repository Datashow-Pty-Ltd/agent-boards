import { afterEach, describe, expect, it, vi } from "vitest";
import { api } from "./api";
import { BOARD_ASSET_COLUMNS } from "./types";

function requestedSelect(fetchMock: ReturnType<typeof vi.fn>) {
  const url = new URL(String(fetchMock.mock.calls[0][0]), "http://board");
  return url.searchParams.get("select")?.split(",") ?? [];
}

describe("board asset requests", () => {
  afterEach(() => vi.unstubAllGlobals());

  it.each([
    ["project board", () => api.boardAssets("project-1")],
    ["single card refresh", () => api.boardItemAssets("item-1")],
  ])("the %s selects card columns only, never inline media", async (_name, load) => {
    const fetchMock = vi.fn(async () => new Response("[]", { status: 200 }));
    vi.stubGlobal("fetch", fetchMock);
    await load();
    const select = requestedSelect(fetchMock);
    expect(select).toEqual([...BOARD_ASSET_COLUMNS, "card_image_url"]);
    expect(select).not.toContain("source_url");
    expect(select).not.toContain("thumbnail_url");
  });

  it("the drawer still loads full assets for one card", async () => {
    const fetchMock = vi.fn(async () => new Response("[]", { status: 200 }));
    vi.stubGlobal("fetch", fetchMock);
    await api.workItemAssets("item-1");
    expect(requestedSelect(fetchMock)).toEqual([]);
  });
});
