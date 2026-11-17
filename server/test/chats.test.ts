import { beforeEach, describe, expect, it } from "vitest";
import { newId } from "../src/lib/ids";
import { addDevice, api, type ChatOut, createDirect, createGroup, fakeWrap, wrapsFor } from "./chat-helpers";
import { env } from "cloudflare:test";
import { insertFamily, insertUserWithDevice, resetDb } from "./helpers";

beforeEach(resetDb);

describe("POST /api/chats", () => {
  it("creates a group with wraps for every member device", async () => {
    const a = await insertUserWithDevice({ name: "A" });
    const b = await insertUserWithDevice({ name: "B" });
    const b2 = await addDevice(b.userId);
    const id = newId();
    const res = await api(a.accessToken, "POST", "/chats", {
      id, kind: "group", title: " Family ", userIds: [b.userId],
      wraps: wrapsFor(id, 1, a.deviceId, [a.deviceId, b.deviceId, b2]),
    });
    expect(res.status).toBe(201);
    const { chat, created } = await res.json<{ chat: ChatOut; created: boolean }>();
    expect(created).toBe(true);
    expect(chat).toMatchObject({
      id, kind: "group", title: "Family", createdBy: a.userId, currentEpoch: 1, epochReady: true, lastSeq: 0, lastMessageAt: null,
    });
    expect(chat.members.map((m) => m.userId).sort()).toEqual([a.userId, b.userId].sort());
    expect(chat.members.every((m) => m.joinedSeq === 0 && m.lastReadSeq === 0)).toBe(true);
  });

  it("direct chat is deduped per pair", async () => {
    const a = await insertUserWithDevice();
    const b = await insertUserWithDevice();
    const first = await createDirect(a, b);
    const id = newId();
    const res = await api(b.accessToken, "POST", "/chats", {
      id, kind: "direct", userId: a.userId, wraps: wrapsFor(id, 1, b.deviceId, [a.deviceId, b.deviceId]),
    });
    expect(res.status).toBe(200);
    const body = await res.json<{ chat: ChatOut; created: boolean }>();
    expect(body.created).toBe(false);
    expect(body.chat.id).toBe(first.id);
    expect(first.kind).toBe("direct");
    expect(first.title).toBeNull();
  });

  it("missing or extra wrap gives wraps_mismatch", async () => {
    const a = await insertUserWithDevice();
    const b = await insertUserWithDevice();
    const b2 = await addDevice(b.userId);
    const stranger = await insertUserWithDevice();
    const id = newId();
    const missing = await api(a.accessToken, "POST", "/chats", {
      id, kind: "group", title: "T", userIds: [b.userId], wraps: wrapsFor(id, 1, a.deviceId, [a.deviceId, b.deviceId]),
    });
    expect(missing.status).toBe(409);
    expect(await missing.json()).toEqual({ error: "wraps_mismatch" });
    const extra = await api(a.accessToken, "POST", "/chats", {
      id, kind: "group", title: "T", userIds: [b.userId],
      wraps: wrapsFor(id, 1, a.deviceId, [a.deviceId, b.deviceId, b2, stranger.deviceId]),
    });
    expect(extra.status).toBe(409);
    const dup = await api(a.accessToken, "POST", "/chats", {
      id, kind: "group", title: "T", userIds: [b.userId],
      wraps: wrapsFor(id, 1, a.deviceId, [a.deviceId, b.deviceId, b2, b2]),
    });
    expect(dup.status).toBe(409);
    const wrongChat = await api(a.accessToken, "POST", "/chats", {
      id, kind: "group", title: "T", userIds: [b.userId],
      wraps: wrapsFor(newId(), 1, a.deviceId, [a.deviceId, b.deviceId, b2]),
    });
    expect(wrongChat.status).toBe(409);
  });

  it("wrapper must be the caller device", async () => {
    const a = await insertUserWithDevice();
    const b = await insertUserWithDevice();
    const id = newId();
    const res = await api(a.accessToken, "POST", "/chats", {
      id, kind: "direct", userId: b.userId, wraps: wrapsFor(id, 1, b.deviceId, [a.deviceId, b.deviceId]),
    });
    expect(res.status).toBe(409);
  });

  it("group needs a title and valid other users (none is a chat with yourself)", async () => {
    const a = await insertUserWithDevice();
    const b = await insertUserWithDevice();
    const id = newId();
    const wraps = wrapsFor(id, 1, a.deviceId, [a.deviceId, b.deviceId]);
    for (const body of [
      { id, kind: "group", title: "  ", userIds: [b.userId], wraps },
      { id, kind: "group", userIds: [b.userId], wraps },
      { id, kind: "group", title: "x".repeat(61), userIds: [b.userId], wraps },
      { id, kind: "group", title: "T", userIds: [a.userId], wraps: wrapsFor(id, 1, a.deviceId, [a.deviceId]) },
      { id: "not-a-ulid", kind: "group", title: "T", userIds: [b.userId], wraps },
      { id, kind: "party", title: "T", userIds: [b.userId], wraps },
      { id, kind: "group", title: "T", userIds: [b.userId], wraps: [{ ...fakeWrap(id, 1, b.deviceId, a.deviceId), sig: "short" }] },
    ]) {
      expect((await api(a.accessToken, "POST", "/chats", body)).status, JSON.stringify(body).slice(0, 80)).toBe(400);
    }
  });

  it("unknown user is refused", async () => {
    const a = await insertUserWithDevice();
    const id = newId();
    const res = await api(a.accessToken, "POST", "/chats", {
      id, kind: "group", title: "T", userIds: [newId()], wraps: wrapsFor(id, 1, a.deviceId, [a.deviceId]),
    });
    expect(res.status).toBe(400);
  });

  it("direct with self is refused", async () => {
    const a = await insertUserWithDevice();
    const id = newId();
    const res = await api(a.accessToken, "POST", "/chats", {
      id, kind: "direct", userId: a.userId, wraps: wrapsFor(id, 1, a.deviceId, [a.deviceId]),
    });
    expect(res.status).toBe(400);
  });

  it("same id re-posted by its creator returns the existing chat", async () => {
    const a = await insertUserWithDevice();
    const b = await insertUserWithDevice();
    const id = newId();
    const body = { id, kind: "group", title: "T", userIds: [b.userId], wraps: wrapsFor(id, 1, a.deviceId, [a.deviceId, b.deviceId]) };
    expect((await api(a.accessToken, "POST", "/chats", body)).status).toBe(201);
    const again = await api(a.accessToken, "POST", "/chats", body);
    expect(again.status).toBe(200);
    expect((await again.json<{ created: boolean }>()).created).toBe(false);
    // Someone else reusing the id is refused.
    const other = await api(b.accessToken, "POST", "/chats", {
      ...body, userIds: [a.userId], wraps: wrapsFor(id, 1, b.deviceId, [a.deviceId, b.deviceId]),
    });
    expect(other.status).toBe(400);
  });
});

describe("GET /api/chats", () => {
  it("list shows only own chats", async () => {
    const a = await insertUserWithDevice();
    const b = await insertUserWithDevice();
    const c = await insertUserWithDevice();
    const ab = await createGroup(a, [b]);
    await createDirect(b, c);
    const res = await api(a.accessToken, "GET", "/chats");
    expect(res.status).toBe(200);
    const { chats } = await res.json<{ chats: ChatOut[] }>();
    expect(chats.map((x) => x.id)).toEqual([ab.id]);
    expect(chats[0].members).toHaveLength(2);
  });

  it("one chat for a member, 404 for anyone else", async () => {
    const a = await insertUserWithDevice();
    const b = await insertUserWithDevice();
    const c = await insertUserWithDevice();
    const ab = await createGroup(a, [b]);
    const ok = await api(b.accessToken, "GET", `/chats/${ab.id}`);
    expect(ok.status).toBe(200);
    expect((await ok.json<{ chat: ChatOut }>()).chat.id).toBe(ab.id);
    expect((await api(c.accessToken, "GET", `/chats/${ab.id}`)).status).toBe(404);
  });
});

describe("PUT /api/chats/:id/mute", () => {
  it("mutes for the caller only, until a time or for good, and unmutes", async () => {
    const a = await insertUserWithDevice();
    const b = await insertUserWithDevice();
    const chat = await createDirect(a, b);
    const until = Date.now() + 3_600_000;
    expect((await api(a.accessToken, "PUT", `/chats/${chat.id}/mute`, { until })).status).toBe(204);
    const mine = await (await api(a.accessToken, "GET", `/chats/${chat.id}`)).json<{ chat: ChatOut }>();
    expect(mine.chat.mutedUntil).toBe(until);
    const list = await (await api(a.accessToken, "GET", "/chats")).json<{ chats: ChatOut[] }>();
    expect(list.chats[0].mutedUntil).toBe(until);
    const theirs = await (await api(b.accessToken, "GET", `/chats/${chat.id}`)).json<{ chat: ChatOut }>();
    expect(theirs.chat.mutedUntil).toBeNull();
    expect((await api(a.accessToken, "PUT", `/chats/${chat.id}/mute`, { until: null })).status).toBe(204);
    const after = await (await api(a.accessToken, "GET", `/chats/${chat.id}`)).json<{ chat: ChatOut }>();
    expect(after.chat.mutedUntil).toBeNull();
  });

  it("rejects bad values and non-members", async () => {
    const a = await insertUserWithDevice();
    const b = await insertUserWithDevice();
    const c = await insertUserWithDevice();
    const chat = await createDirect(a, b);
    for (const body of [{}, { until: "soon" }, { until: 1.5 }, { until: -1 }, { until: 1e17 }]) {
      expect((await api(a.accessToken, "PUT", `/chats/${chat.id}/mute`, body)).status).toBe(400);
    }
    expect((await api(c.accessToken, "PUT", `/chats/${chat.id}/mute`, { until: null })).status).toBe(404);
  });
});

describe("chats and families", () => {
  const post = (u: { accessToken: string; deviceId: string }, devs: string[], extra: Record<string, unknown>) => {
    const id = newId();
    return api(u.accessToken, "POST", "/chats", { id, wraps: wrapsFor(id, 1, u.deviceId, devs), ...extra }).then((res) => ({ id, res }));
  };

  it("a group without familyId goes to the caller's only family", async () => {
    const a = await insertUserWithDevice();
    const b = await insertUserWithDevice();
    expect((await createGroup(a, [b])).familyId).toBe(1);
    const r1 = await insertUserWithDevice({ reviewer: true });
    const r2 = await insertUserWithDevice({ reviewer: true });
    expect((await createGroup(r1, [r2])).familyId).toBe(2);
    expect((await createGroup(r1, [], "Note to self")).familyId).toBe(2);
    const d = await createDirect(a, b);
    expect(d.familyId).toBeNull();
  });

  it("an old client in several families gets family #1, or 400 without it", async () => {
    const f3 = await insertFamily();
    const f4 = await insertFamily();
    const a = await insertUserWithDevice({ families: [{ id: 1 }, { id: f3 }] });
    const b = await insertUserWithDevice({ families: [{ id: 1 }, { id: f3 }] });
    expect((await createGroup(a, [b])).familyId).toBe(1);
    const c = await insertUserWithDevice({ families: [{ id: f3 }, { id: f4 }] });
    const d = await insertUserWithDevice({ families: [{ id: f3 }, { id: f4 }] });
    const { res } = await post(c, [c.deviceId, d.deviceId], { kind: "group", title: "T", userIds: [d.userId] });
    expect(res.status).toBe(400);
    const ok = await post(c, [c.deviceId, d.deviceId], { kind: "group", title: "T", userIds: [d.userId], familyId: f4 });
    expect(ok.res.status).toBe(201);
    expect((await ok.res.json<{ chat: ChatOut }>()).chat.familyId).toBe(f4);
  });

  it("every group member must be a live member of the group's family", async () => {
    const f3 = await insertFamily();
    const pending = await insertFamily({ status: "pending" });
    const a = await insertUserWithDevice({ families: [{ id: 1 }, { id: f3 }, { id: pending }] });
    const onlyOne = await insertUserWithDevice();
    const both = await insertUserWithDevice({ families: [{ id: 1 }, { id: f3 }, { id: pending }] });
    const bad = await post(a, [a.deviceId, onlyOne.deviceId], { kind: "group", title: "T", userIds: [onlyOne.userId], familyId: f3 });
    expect(bad.res.status).toBe(400);
    const pend = await post(a, [a.deviceId, both.deviceId], { kind: "group", title: "T", userIds: [both.userId], familyId: pending });
    expect(pend.res.status).toBe(400);
    const outsider = await insertUserWithDevice({ families: [{ id: f3 }] });
    const non = await post(outsider, [outsider.deviceId, both.deviceId], { kind: "group", title: "T", userIds: [both.userId], familyId: 1 });
    expect(non.res.status).toBe(400);
    const ok = await post(a, [a.deviceId, both.deviceId], { kind: "group", title: "T", userIds: [both.userId], familyId: f3 });
    expect(ok.res.status).toBe(201);
    // A deleted member doesn't count as live.
    await env.DB.prepare("UPDATE users SET deleted_at = 1 WHERE id = ?").bind(both.userId).run();
    const gone = await post(a, [a.deviceId], { kind: "group", title: "T", userIds: [both.userId], familyId: f3 });
    expect(gone.res.status).toBe(400);
  });

  it("a direct chat needs a shared family", async () => {
    const f3 = await insertFamily();
    const a = await insertUserWithDevice();
    const b = await insertUserWithDevice({ families: [{ id: f3 }] });
    const res = await post(a, [a.deviceId, b.deviceId], { kind: "direct", userId: b.userId });
    expect(res.res.status).toBe(403);
    expect(await res.res.json()).toEqual({ error: "no_shared_family" });
    const gone = await insertUserWithDevice();
    await env.DB.prepare("UPDATE users SET deleted_at = 1 WHERE id = ?").bind(gone.userId).run();
    expect((await post(a, [a.deviceId, gone.deviceId], { kind: "direct", userId: gone.userId })).res.status).toBe(400);
    expect((await post(a, [a.deviceId], { kind: "direct", userId: newId() })).res.status).toBe(400);
    // An existing pair is still returned after they stop sharing.
    const c = await insertUserWithDevice();
    const d = await createDirect(a, c);
    await env.DB.prepare("DELETE FROM family_members WHERE user_id = ?").bind(c.userId).run();
    const again = await api(a.accessToken, "POST", "/chats", {
      id: newId(), kind: "direct", userId: c.userId, wraps: [],
    });
    expect(again.status).toBe(200);
    expect((await again.json<{ chat: ChatOut }>()).chat.id).toBe(d.id);
  });
});
