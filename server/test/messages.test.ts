import { beforeEach, describe, expect, it } from "vitest";
import { api, createGroup, insertMessage } from "./chat-helpers";
import { insertUserWithDevice, resetDb } from "./helpers";

beforeEach(resetDb);

type Msg = { chatId: string; seq: number; id: string; senderUserId: string; senderDeviceId: string; envelope: unknown; createdAt: number };
const list = async (token: string, chatId: string, q = "") =>
  (await (await api(token, "GET", `/chats/${chatId}/messages${q}`)).json<{ messages: Msg[] }>()).messages;

describe("GET /api/chats/:id/messages", () => {
  it("after returns ascending rows above seq", async () => {
    const a = await insertUserWithDevice();
    const b = await insertUserWithDevice();
    const chat = await createGroup(a, [b]);
    const ids = [];
    for (let i = 0; i < 5; i++) ids.push(await insertMessage(chat.id, i % 2 ? b : a));
    const all = await list(b.accessToken, chat.id);
    expect(all.map((m) => m.seq)).toEqual([1, 2, 3, 4, 5]);
    expect(all[0]).toMatchObject({ chatId: chat.id, id: ids[0], senderUserId: a.userId, senderDeviceId: a.deviceId });
    expect(all[0].envelope).toEqual({ v: 1, epoch: 1, nonce: "AA", ct: "AA", sig: "AA" });
    expect((await list(b.accessToken, chat.id, "?after=3")).map((m) => m.seq)).toEqual([4, 5]);
    expect((await list(b.accessToken, chat.id, "?after=1&limit=2")).map((m) => m.seq)).toEqual([2, 3]);
  });

  it("before returns the latest rows below seq, ascending", async () => {
    const a = await insertUserWithDevice();
    const chat = await createGroup(a, [await insertUserWithDevice()]);
    for (let i = 0; i < 6; i++) await insertMessage(chat.id, a);
    expect((await list(a.accessToken, chat.id, "?before=6&limit=2")).map((m) => m.seq)).toEqual([4, 5]);
  });

  it("limit is capped at 200 and bad params are refused", async () => {
    const a = await insertUserWithDevice();
    const chat = await createGroup(a, [await insertUserWithDevice()]);
    for (let i = 0; i < 3; i++) await insertMessage(chat.id, a);
    expect((await api(a.accessToken, "GET", `/chats/${chat.id}/messages?limit=500`)).status).toBe(200);
    expect((await api(a.accessToken, "GET", `/chats/${chat.id}/messages?after=x`)).status).toBe(400);
    expect((await api(a.accessToken, "GET", `/chats/${chat.id}/messages?after=1&before=3`)).status).toBe(400);
  });

  it("non-member gets 404", async () => {
    const a = await insertUserWithDevice();
    const chat = await createGroup(a, [await insertUserWithDevice()]);
    expect((await api((await insertUserWithDevice()).accessToken, "GET", `/chats/${chat.id}/messages`)).status).toBe(404);
  });
});
