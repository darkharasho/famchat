import { beforeEach, describe, expect, it } from "vitest";
import { addDevice, api, type ChatOut, createDirect, createGroup, insertMessage, wrapsFor } from "./chat-helpers";
import { insertFamily, insertUserWithDevice, joinFamily, resetDb } from "./helpers";
import { env } from "cloudflare:test";

beforeEach(resetDb);

const getChat = async (token: string, id: string) => (await (await api(token, "GET", `/chats/${id}`)).json<{ chat: ChatOut }>()).chat;

describe("POST /api/chats/:id/members", () => {
  it("adds to a group with current-epoch wraps", async () => {
    const a = await insertUserWithDevice();
    const b = await insertUserWithDevice();
    const c = await insertUserWithDevice();
    const chat = await createGroup(a, [b]);
    await insertMessage(chat.id, a);
    await insertMessage(chat.id, b);
    const res = await api(b.accessToken, "POST", `/chats/${chat.id}/members`, {
      userIds: [c.userId],
      wraps: wrapsFor(chat.id, 1, b.deviceId, [c.deviceId]),
    });
    expect(res.status).toBe(200);
    const out = (await res.json<{ chat: ChatOut }>()).chat;
    expect(out.members.find((m) => m.userId === c.userId)).toEqual({ userId: c.userId, joinedSeq: 2, lastReadSeq: 0 });
    // The new member can read the history.
    expect((await api(c.accessToken, "GET", `/chats/${chat.id}/messages`)).status).toBe(200);
  });

  it("refuses an add without wraps for every new device", async () => {
    const a = await insertUserWithDevice();
    const b = await insertUserWithDevice();
    const c = await insertUserWithDevice();
    await addDevice(c.userId);
    const chat = await createGroup(a, [b]);
    const res = await api(a.accessToken, "POST", `/chats/${chat.id}/members`, {
      userIds: [c.userId], wraps: wrapsFor(chat.id, 1, a.deviceId, [c.deviceId]),
    });
    expect(res.status).toBe(409);
    expect(await res.json()).toEqual({ error: "wraps_mismatch" });
  });

  it("refuses adding to a direct chat, existing members and non-members' calls", async () => {
    const a = await insertUserWithDevice();
    const b = await insertUserWithDevice();
    const c = await insertUserWithDevice();
    const d = await createDirect(a, b);
    expect((await api(a.accessToken, "POST", `/chats/${d.id}/members`, {
      userIds: [c.userId], wraps: wrapsFor(d.id, 1, a.deviceId, [c.deviceId]),
    })).status).toBe(400);
    const g = await createGroup(a, [b]);
    expect((await api(a.accessToken, "POST", `/chats/${g.id}/members`, {
      userIds: [b.userId], wraps: wrapsFor(g.id, 1, a.deviceId, [b.deviceId]),
    })).status).toBe(400);
    expect((await api(c.accessToken, "POST", `/chats/${g.id}/members`, {
      userIds: [c.userId], wraps: wrapsFor(g.id, 1, c.deviceId, [c.deviceId]),
    })).status).toBe(404);
  });
});

describe("DELETE /api/chats/:id/members/:userId", () => {
  it("leave bumps the epoch", async () => {
    const a = await insertUserWithDevice();
    const b = await insertUserWithDevice();
    const c = await insertUserWithDevice();
    const chat = await createGroup(a, [b, c]);
    expect((await api(c.accessToken, "DELETE", `/chats/${chat.id}/members/${c.userId}`)).status).toBe(204);
    const out = await getChat(a.accessToken, chat.id);
    expect(out.currentEpoch).toBe(2);
    expect(out.epochReady).toBe(false);
    expect(out.members.map((m) => m.userId)).not.toContain(c.userId);
  });

  it("creator removes a member; others cannot", async () => {
    const a = await insertUserWithDevice();
    const b = await insertUserWithDevice();
    const c = await insertUserWithDevice();
    const chat = await createGroup(a, [b, c]);
    expect((await api(b.accessToken, "DELETE", `/chats/${chat.id}/members/${c.userId}`)).status).toBe(403);
    expect((await api(a.accessToken, "DELETE", `/chats/${chat.id}/members/${c.userId}`)).status).toBe(204);
    expect((await api(a.accessToken, "DELETE", `/chats/${chat.id}/members/${c.userId}`)).status).toBe(404);
    expect((await getChat(a.accessToken, chat.id)).currentEpoch).toBe(2);
  });

  it("removed user can no longer read messages", async () => {
    const a = await insertUserWithDevice();
    const b = await insertUserWithDevice();
    const c = await insertUserWithDevice();
    const chat = await createGroup(a, [b, c]);
    await api(a.accessToken, "DELETE", `/chats/${chat.id}/members/${c.userId}`);
    expect((await api(c.accessToken, "GET", `/chats/${chat.id}/messages`)).status).toBe(404);
    expect((await api(c.accessToken, "GET", `/chats/${chat.id}`)).status).toBe(404);
  });

  it("direct chats can't be left", async () => {
    const a = await insertUserWithDevice();
    const b = await insertUserWithDevice();
    const d = await createDirect(a, b);
    expect((await api(a.accessToken, "DELETE", `/chats/${d.id}/members/${a.userId}`)).status).toBe(400);
  });
});

describe("POST /api/chats/:id/epochs", () => {
  async function afterLeave() {
    const a = await insertUserWithDevice();
    const b = await insertUserWithDevice();
    const c = await insertUserWithDevice();
    const chat = await createGroup(a, [b, c]);
    await api(c.accessToken, "DELETE", `/chats/${chat.id}/members/${c.userId}`);
    return { a, b, c, chat };
  }

  it("creates the next epoch once", async () => {
    const { a, b, chat } = await afterLeave();
    const res = await api(b.accessToken, "POST", `/chats/${chat.id}/epochs`, {
      epoch: 2, wraps: wrapsFor(chat.id, 2, b.deviceId, [a.deviceId, b.deviceId]),
    });
    expect(res.status).toBe(201);
    expect((await getChat(a.accessToken, chat.id)).epochReady).toBe(true);
    const second = await api(a.accessToken, "POST", `/chats/${chat.id}/epochs`, {
      epoch: 2, wraps: wrapsFor(chat.id, 2, a.deviceId, [a.deviceId, b.deviceId]),
    });
    expect(second.status).toBe(409);
    expect(await second.json()).toEqual({ error: "epoch_exists" });
  });

  it("an old epoch is stale", async () => {
    const { a, b, chat } = await afterLeave();
    const res = await api(a.accessToken, "POST", `/chats/${chat.id}/epochs`, {
      epoch: 1, wraps: wrapsFor(chat.id, 1, a.deviceId, [a.deviceId, b.deviceId]),
    });
    expect(res.status).toBe(409);
    expect(await res.json()).toEqual({ error: "stale_epoch" });
  });

  it("wraps must cover live member devices only", async () => {
    const { a, b, c, chat } = await afterLeave();
    const res = await api(a.accessToken, "POST", `/chats/${chat.id}/epochs`, {
      epoch: 2, wraps: wrapsFor(chat.id, 2, a.deviceId, [a.deviceId, b.deviceId, c.deviceId]),
    });
    expect(res.status).toBe(409);
    expect(await res.json()).toEqual({ error: "wraps_mismatch" });
    expect((await api(c.accessToken, "POST", `/chats/${chat.id}/epochs`, {
      epoch: 2, wraps: wrapsFor(chat.id, 2, c.deviceId, [a.deviceId, b.deviceId]),
    })).status).toBe(404);
  });
});

describe("family rules for members", () => {
  it("group adds are limited to the group's family", async () => {
    const f3 = await insertFamily();
    const a = await insertUserWithDevice({ families: [{ id: 1 }, { id: f3 }] });
    const b = await insertUserWithDevice({ families: [{ id: 1 }, { id: f3 }] });
    const inF3 = await insertUserWithDevice({ families: [{ id: f3 }] });
    const inOne = await insertUserWithDevice();
    const chat = await createGroup(a, [b]);
    expect(chat.familyId).toBe(1);
    const bad = await api(a.accessToken, "POST", `/chats/${chat.id}/members`, {
      userIds: [inF3.userId], wraps: wrapsFor(chat.id, 1, a.deviceId, [inF3.deviceId]),
    });
    expect(bad.status).toBe(400);
    const ok = await api(a.accessToken, "POST", `/chats/${chat.id}/members`, {
      userIds: [inOne.userId], wraps: wrapsFor(chat.id, 1, a.deviceId, [inOne.deviceId]),
    });
    expect(ok.status).toBe(200);
  });

  it("leaving a group records a leaver", async () => {
    const a = await insertUserWithDevice();
    const b = await insertUserWithDevice();
    const c = await insertUserWithDevice();
    const chat = await createGroup(a, [b, c]);
    expect((await api(c.accessToken, "DELETE", `/chats/${chat.id}/members/${c.userId}`)).status).toBe(204);
    expect((await api(a.accessToken, "DELETE", `/chats/${chat.id}/members/${b.userId}`)).status).toBe(204);
    const { results } = await env.DB.prepare("SELECT user_id FROM chat_leavers WHERE chat_id = ?").bind(chat.id)
      .all<{ user_id: string }>();
    expect(results.map((r) => r.user_id).sort()).toEqual([b.userId, c.userId].sort());
  });
});
