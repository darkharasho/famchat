import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { api, createDirect, createGroup, insertMessage, type TestUser } from "./chat-helpers";
import { insertUserWithDevice, resetDb } from "./helpers";
import { closeSockets, socket } from "./ws-helpers";

beforeEach(resetDb);
afterEach(closeSockets);

type Star = { chatId: string; messageId: string; starredAt: number };
const stars = async (u: TestUser) => (await (await api(u.accessToken, "GET", "/me/stars")).json<{ stars: Star[] }>()).stars;
const star = (u: TestUser, chatId: string, messageId: string, on = true) =>
  api(u.accessToken, on ? "PUT" : "DELETE", `/chats/${chatId}/messages/${messageId}/star`);

describe("starred messages", () => {
  it("are starred and unstarred for the caller only, newest first, idempotently", async () => {
    const a = await insertUserWithDevice();
    const b = await insertUserWithDevice();
    const chat = await createDirect(a, b);
    const m1 = await insertMessage(chat.id, b);
    const m2 = await insertMessage(chat.id, a);
    expect((await star(a, chat.id, m1)).status).toBe(204);
    await new Promise((r) => setTimeout(r, 2));
    expect((await star(a, chat.id, m2)).status).toBe(204);
    expect((await star(a, chat.id, m2)).status).toBe(204);
    expect((await stars(a)).map((s) => s.messageId)).toEqual([m2, m1]);
    expect(await stars(b)).toEqual([]);
    expect((await star(a, chat.id, m1, false)).status).toBe(204);
    expect((await star(a, chat.id, m1, false)).status).toBe(204);
    expect((await stars(a)).map((s) => s.messageId)).toEqual([m2]);
  });

  it("tell only the caller's own sockets, and only when something changed", async () => {
    const a = await insertUserWithDevice();
    const b = await insertUserWithDevice();
    const chat = await createDirect(a, b);
    const m = await insertMessage(chat.id, b);
    const sa = await socket(a);
    const sb = await socket(b);
    await star(a, chat.id, m);
    expect(await sa.next("stars")).toEqual({ type: "stars" });
    await sb.none("stars");
    await star(a, chat.id, m);
    await sa.none("stars");
  });

  it("refuse non-members, unknown messages and messages from another chat", async () => {
    const a = await insertUserWithDevice();
    const b = await insertUserWithDevice();
    const c = await insertUserWithDevice();
    const chat = await createDirect(a, b);
    const other = await createDirect(a, c);
    const m = await insertMessage(chat.id, b);
    expect((await star(c, chat.id, m)).status).toBe(404);
    expect((await star(a, other.id, m)).status).toBe(404);
    expect((await star(a, chat.id, "01JC0000000000000000000000")).status).toBe(404);
    expect((await star(a, chat.id, "nope")).status).toBe(404);
  });

  it("go when the user leaves the group", async () => {
    const a = await insertUserWithDevice();
    const b = await insertUserWithDevice();
    const c = await insertUserWithDevice();
    const group = await createGroup(a, [b, c]);
    const m = await insertMessage(group.id, b);
    await star(c, group.id, m);
    expect(await stars(c)).toHaveLength(1);
    expect((await api(c.accessToken, "DELETE", `/chats/${group.id}/members/${c.userId}`)).status).toBe(204);
    expect(await stars(c)).toEqual([]);
  });

  it("go with a deleted message (its sender deleted their account)", async () => {
    const a = await insertUserWithDevice();
    const b = await insertUserWithDevice();
    const chat = await createDirect(a, b);
    const m = await insertMessage(chat.id, b);
    await star(a, chat.id, m);
    expect((await api(b.accessToken, "DELETE", "/me", { confirm: "delete" })).status).toBe(204);
    expect(await stars(a)).toEqual([]);
  });
});
