import { beforeEach, describe, expect, it } from "vitest";
import { newId } from "../src/lib/ids";
import { addDevice, api, type ChatOut, createDirect, createGroup, fakeWrap, wrapsFor } from "./chat-helpers";
import { insertUserWithDevice, resetDb } from "./helpers";

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

  it("group needs a title and other users", async () => {
    const a = await insertUserWithDevice();
    const b = await insertUserWithDevice();
    const id = newId();
    const wraps = wrapsFor(id, 1, a.deviceId, [a.deviceId, b.deviceId]);
    for (const body of [
      { id, kind: "group", title: "  ", userIds: [b.userId], wraps },
      { id, kind: "group", userIds: [b.userId], wraps },
      { id, kind: "group", title: "x".repeat(61), userIds: [b.userId], wraps },
      { id, kind: "group", title: "T", userIds: [], wraps: wrapsFor(id, 1, a.deviceId, [a.deviceId]) },
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
