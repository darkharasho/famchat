import { SELF } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { api, type ChatOut, createDirect, createGroup, type TestUser } from "./chat-helpers";
import { BASE, insertUserWithDevice, resetDb } from "./helpers";
import { closeSockets, socket } from "./ws-helpers";

beforeEach(resetDb);
afterEach(closeSockets);

const chatOf = async (u: TestUser, id: string) =>
  (await (await api(u.accessToken, "GET", `/chats/${id}`)).json<{ chat: ChatOut }>()).chat;

describe("PATCH /api/chats/:id/me", () => {
  it("pins, archives and marks unread for the caller only", async () => {
    const a = await insertUserWithDevice();
    const b = await insertUserWithDevice();
    const chat = await createDirect(a, b);
    const before = Date.now();
    expect((await api(a.accessToken, "PATCH", `/chats/${chat.id}/me`, { pinned: true, archived: true, unread: true })).status)
      .toBe(204);
    const mine = await chatOf(a, chat.id);
    expect(mine.pinnedAt).toBeGreaterThanOrEqual(before);
    expect(mine.archivedAt).toBeGreaterThanOrEqual(before);
    expect(mine.markedUnread).toBe(true);
    const list = (await (await api(a.accessToken, "GET", "/chats")).json<{ chats: ChatOut[] }>()).chats;
    expect(list[0]).toMatchObject({ pinnedAt: mine.pinnedAt, archivedAt: mine.archivedAt, markedUnread: true });
    expect(await chatOf(b, chat.id)).toMatchObject({ pinnedAt: null, archivedAt: null, markedUnread: false });

    // Each field on its own; the others stay.
    expect((await api(a.accessToken, "PATCH", `/chats/${chat.id}/me`, { unread: false })).status).toBe(204);
    expect(await chatOf(a, chat.id)).toMatchObject({ pinnedAt: mine.pinnedAt, archivedAt: mine.archivedAt, markedUnread: false });
    expect((await api(a.accessToken, "PATCH", `/chats/${chat.id}/me`, { pinned: false, archived: false })).status).toBe(204);
    expect(await chatOf(a, chat.id)).toMatchObject({ pinnedAt: null, archivedAt: null });
  });

  it("tells only the caller's own sockets", async () => {
    const a = await insertUserWithDevice();
    const b = await insertUserWithDevice();
    const chat = await createDirect(a, b);
    const sa = await socket(a);
    const sb = await socket(b);
    await api(a.accessToken, "PATCH", `/chats/${chat.id}/me`, { pinned: true });
    expect(await sa.next("chat")).toEqual({ type: "chat", chatId: chat.id });
    await sb.none("chat");
  });

  it("rejects bad bodies and non-members", async () => {
    const a = await insertUserWithDevice();
    const b = await insertUserWithDevice();
    const c = await insertUserWithDevice();
    const chat = await createDirect(a, b);
    for (const body of [{}, { pinned: 1 }, { archived: "yes" }, { unread: null }]) {
      expect((await api(a.accessToken, "PATCH", `/chats/${chat.id}/me`, body)).status).toBe(400);
    }
    expect((await api(c.accessToken, "PATCH", `/chats/${chat.id}/me`, { pinned: true })).status).toBe(404);
  });
});

describe("PATCH /api/chats/:id", () => {
  it("any member renames a group, and every member hears", async () => {
    const a = await insertUserWithDevice();
    const b = await insertUserWithDevice();
    const chat = await createGroup(a, [b]);
    const sa = await socket(a);
    const res = await api(b.accessToken, "PATCH", `/chats/${chat.id}`, { title: "  Cousins  " });
    expect(res.status).toBe(200);
    expect((await res.json<{ chat: ChatOut }>()).chat.title).toBe("Cousins");
    expect(await sa.next("chat")).toEqual({ type: "chat", chatId: chat.id });
    expect((await chatOf(a, chat.id)).title).toBe("Cousins");
  });

  it("rejects direct chats, bad titles and non-members", async () => {
    const a = await insertUserWithDevice();
    const b = await insertUserWithDevice();
    const c = await insertUserWithDevice();
    const direct = await createDirect(a, b);
    const group = await createGroup(a, [b]);
    expect((await api(a.accessToken, "PATCH", `/chats/${direct.id}`, { title: "X" })).status).toBe(400);
    for (const title of ["", "  ", "x".repeat(61), "a\nb", 5]) {
      expect((await api(a.accessToken, "PATCH", `/chats/${group.id}`, { title })).status).toBe(400);
    }
    expect((await api(c.accessToken, "PATCH", `/chats/${group.id}`, { title: "Mine" })).status).toBe(404);
  });
});

/** A tiny "JPEG": the SOI marker and some bytes. */
const jpeg = (n = 100, fill = 7) => {
  const b = new Uint8Array(n).fill(fill);
  b.set([0xff, 0xd8, 0xff]);
  return b;
};

const putPhoto = (u: TestUser, chatId: string, body: Uint8Array, type = "image/jpeg") =>
  SELF.fetch(`${BASE}/api/chats/${chatId}/avatar`, {
    method: "PUT",
    headers: { authorization: `Bearer ${u.accessToken}`, "content-type": type },
    body,
  });

const getPhoto = (u: TestUser, chatId: string, v?: string) =>
  SELF.fetch(`${BASE}/api/chats/${chatId}/avatar${v ? `?v=${v}` : ""}`, { headers: { authorization: `Bearer ${u.accessToken}` } });

describe("group photos", () => {
  it("are set by any member, served to members, replaced and removed", async () => {
    const a = await insertUserWithDevice();
    const b = await insertUserWithDevice();
    const c = await insertUserWithDevice();
    const chat = await createGroup(a, [b]);
    expect(chat.avatarKey).toBeNull();
    const sa = await socket(a);

    const res = await putPhoto(b, chat.id, jpeg(100));
    expect(res.status).toBe(200);
    const { avatarKey } = await res.json<{ avatarKey: string }>();
    expect(await sa.next("chat")).toEqual({ type: "chat", chatId: chat.id });
    expect((await chatOf(a, chat.id)).avatarKey).toBe(avatarKey);
    const got = await getPhoto(a, chat.id, avatarKey);
    expect(got.status).toBe(200);
    expect(got.headers.get("cache-control")).toContain("immutable");
    expect(new Uint8Array(await got.arrayBuffer())).toEqual(jpeg(100));
    expect((await getPhoto(c, chat.id, avatarKey)).status).toBe(404);

    const second = await (await putPhoto(a, chat.id, jpeg(50, 9))).json<{ avatarKey: string }>();
    expect(second.avatarKey).not.toBe(avatarKey);
    expect((await getPhoto(a, chat.id, avatarKey)).status).toBe(404);
    expect((await getPhoto(a, chat.id, second.avatarKey)).status).toBe(200);

    expect((await api(b.accessToken, "DELETE", `/chats/${chat.id}/avatar`)).status).toBe(204);
    expect((await chatOf(a, chat.id)).avatarKey).toBeNull();
    expect((await getPhoto(a, chat.id)).status).toBe(404);
  });

  it("rejects direct chats, non-JPEGs and big files", async () => {
    const a = await insertUserWithDevice();
    const b = await insertUserWithDevice();
    const direct = await createDirect(a, b);
    const group = await createGroup(a, [b]);
    expect((await putPhoto(a, direct.id, jpeg())).status).toBe(400);
    expect((await putPhoto(a, group.id, jpeg(), "image/png")).status).toBe(400);
    expect((await putPhoto(a, group.id, new Uint8Array(100))).status).toBe(400);
    expect((await putPhoto(a, group.id, jpeg(300 * 1024))).status).toBe(413);
  });
});
