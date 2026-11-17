import { env, runInDurableObject, SELF } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { type FamilyHub, type PushJob, queuePush, STALE_SOCKET_MS } from "../src/hub";
import { newId } from "../src/lib/ids";
import { addDevice, api, type ChatOut, createDirect, createGroup, type TestUser, wrapsFor } from "./chat-helpers";
import { notifyReset } from "../src/lib/reset-account";
import { BASE, insertFamily, insertUserWithDevice, joinFamily, redeemNewDevice, resetDb } from "./helpers";

type Msg = Record<string, unknown> & { type: string };

interface Client {
  ws: WebSocket;
  send(m: unknown): void;
  next(type: string, timeoutMs?: number): Promise<Msg>;
  none(type: string, waitMs?: number): Promise<void>;
  closed: Promise<number>;
  /** Every message received, in order (never consumed by [next]). */
  log: Msg[];
}

const open: WebSocket[] = [];

async function ticket(u: TestUser): Promise<string> {
  const res = await api(u.accessToken, "POST", "/ws/ticket");
  expect(res.status).toBe(200);
  const body = await res.json<{ ticket: string; expiresAt: number }>();
  expect(body.expiresAt).toBeGreaterThan(Date.now());
  return body.ticket;
}

function upgrade(t: string) {
  return SELF.fetch(`${BASE}/api/ws?ticket=${encodeURIComponent(t)}`, { headers: { upgrade: "websocket" } });
}

async function connect(u: TestUser): Promise<Client> {
  const res = await upgrade(await ticket(u));
  expect(res.status).toBe(101);
  const ws = res.webSocket!;
  ws.accept();
  open.push(ws);
  const inbox: Msg[] = [];
  const log: Msg[] = [];
  let wake: (() => void) | null = null;
  ws.addEventListener("message", (e) => {
    const m = JSON.parse(e.data as string) as Msg;
    inbox.push(m);
    log.push(m);
    wake?.();
  });
  const closed = new Promise<number>((r) => ws.addEventListener("close", (e) => r(e.code)));
  const take = (type: string) => {
    const i = inbox.findIndex((m) => m.type === type);
    return i < 0 ? null : inbox.splice(i, 1)[0];
  };
  return {
    ws,
    closed,
    log,
    send: (m) => ws.send(JSON.stringify(m)),
    async next(type, timeoutMs = 2000) {
      const deadline = Date.now() + timeoutMs;
      for (;;) {
        const m = take(type);
        if (m) return m;
        if (Date.now() > deadline) throw new Error(`no ${type} message; inbox: ${JSON.stringify(inbox)}`);
        await new Promise<void>((r) => {
          wake = r;
          setTimeout(r, 20);
        });
      }
    },
    async none(type, waitMs = 150) {
      await new Promise((r) => setTimeout(r, waitMs));
      expect(inbox.filter((m) => m.type === type)).toEqual([]);
    },
  };
}

const setPushToken = (deviceId: string, tok: string) =>
  env.DB.prepare("UPDATE devices SET push_token = ? WHERE id = ?").bind(tok, deviceId).run();

const envelope = (epoch = 1) => ({ v: 1, epoch, nonce: "AAAA", ct: "AAAAAAAAAAAAAAAAAAAAAA", sig: "AAAA" });

beforeEach(resetDb);
afterEach(async () => {
  for (const ws of open.splice(0)) {
    try {
      ws.close(1000, "done");
    } catch {
      /* already closed */
    }
  }
  await new Promise((r) => setTimeout(r, 30));
});

describe("WebSocket tickets", () => {
  it("a ticket works once", async () => {
    const a = await insertUserWithDevice();
    const t = await ticket(a);
    const first = await upgrade(t);
    expect(first.status).toBe(101);
    first.webSocket!.accept();
    open.push(first.webSocket!);
    expect((await upgrade(t)).status).toBe(401);
  });

  it("an expired ticket is refused", async () => {
    const a = await insertUserWithDevice();
    const t = await ticket(a);
    await env.DB.prepare("UPDATE ws_tickets SET expires_at = 1").run();
    expect((await upgrade(t)).status).toBe(401);
  });

  it("a revoked device's ticket is refused", async () => {
    const a = await insertUserWithDevice();
    const t = await ticket(a);
    await env.DB.prepare("UPDATE devices SET revoked_at = 1 WHERE id = ?").bind(a.deviceId).run();
    expect((await upgrade(t)).status).toBe(401);
  });

  it("needs an upgrade header", async () => {
    const a = await insertUserWithDevice();
    const res = await SELF.fetch(`${BASE}/api/ws?ticket=${await ticket(a)}`);
    expect(res.status).toBe(426);
    expect(await res.json()).toEqual({ error: "upgrade_required" });
  });

  it("ticket needs auth", async () => {
    expect((await SELF.fetch(`${BASE}/api/ws/ticket`, { method: "POST" })).status).toBe(401);
  });
});

describe("presence", () => {
  it("hello lists online users and presence follows connections", async () => {
    const a = await insertUserWithDevice();
    const b = await insertUserWithDevice();
    const ca = await connect(a);
    expect((await ca.next("hello")).online).toContain(a.userId);
    const cb = await connect(b);
    const hello = await cb.next("hello");
    expect(hello.online).toEqual(expect.arrayContaining([a.userId, b.userId]));
    expect(await ca.next("presence")).toEqual({ type: "presence", userId: b.userId, online: true });
    cb.ws.close(1000, "bye");
    expect(await ca.next("presence")).toEqual({ type: "presence", userId: b.userId, online: false });
  });

  it("a second device of an online user does not repeat presence", async () => {
    const a = await insertUserWithDevice();
    const b = await insertUserWithDevice();
    const ca = await connect(a);
    await connect(b);
    await ca.next("presence");
    await connect(b);
    await ca.none("presence");
  });

  it("a quick reconnect during a cold peer load does not end with a stale offline", async () => {
    const a = await insertUserWithDevice();
    const b = await insertUserWithDevice();
    const ca = await connect(a);
    const cb = await connect(b);
    await ca.next("presence");
    // Cold cache, as after hibernation: the close has to load B's peers from D1.
    await hubStub().sharesChanged();
    // Hold that load open (a slow D1 read) so the reconnect lands inside it.
    const g = await gate("peersOf");
    cb.ws.close(1000, "bye");
    await g.entered();
    const cb2 = await connect(b);
    await cb2.next("hello");
    await g.release();
    await new Promise((r) => setTimeout(r, 100));
    const seen = ca.log.filter((m) => m.type === "presence" && m.userId === b.userId);
    expect(seen.at(-1)).toEqual({ type: "presence", userId: b.userId, online: true });
  });

  it("hello is the first thing a new socket hears", async () => {
    const a = await insertUserWithDevice();
    // Hold the hello's online lookup open; an event for A arrives meanwhile.
    const g = await gate("onlineUserIds");
    const pending = connect(a);
    await g.entered();
    await hubStub().notify([a.userId], { type: "profile", userId: a.userId });
    await g.release();
    const ca = await pending;
    await ca.next("hello");
    expect(ca.log[0]?.type).toBe("hello");
  });
});

const hubStub = () => env.HUB.get(env.HUB.idFromName("family"));

/**
 * Holds the hub's next call of [method] until released (a slow D1 read, made deterministic). Only
 * the first call is held; the patch is removed on release.
 */
async function gate(method: "peersOf" | "onlineUserIds") {
  type G = { entered: boolean; release: () => void };
  type H = Record<string, unknown> & { __gate?: G };
  await runInDurableObject(hubStub(), (hub: FamilyHub) => {
    const h = hub as unknown as H;
    const orig = (h[method] as (...a: unknown[]) => Promise<unknown>).bind(hub);
    let release!: () => void;
    const held = new Promise<void>((r) => (release = r));
    const g: G = { entered: false, release };
    h.__gate = g;
    h[method] = async (...args: unknown[]) => {
      if (!g.entered) {
        g.entered = true;
        await held;
      }
      return orig(...args);
    };
  });
  return {
    async entered() {
      for (let i = 0; i < 100; i++) {
        if (await runInDurableObject(hubStub(), (hub: FamilyHub) => (hub as unknown as H).__gate?.entered)) return;
        await new Promise((r) => setTimeout(r, 10));
      }
      throw new Error(`${method} was never called`);
    },
    async release() {
      await runInDurableObject(hubStub(), (hub: FamilyHub) => {
        const h = hub as unknown as H;
        delete h[method];
        h.__gate?.release();
        delete h.__gate;
      });
    },
  };
}

describe("send", () => {
  it("acks with gap-free seqs and fans out to members only", async () => {
    const a = await insertUserWithDevice();
    const b = await insertUserWithDevice();
    const stranger = await insertUserWithDevice();
    const chat = await createGroup(a, [b]);
    const ca = await connect(a);
    const cb = await connect(b);
    const cs = await connect(stranger);
    const id1 = newId();
    const id2 = newId();
    ca.send({ type: "send", id: id1, chatId: chat.id, envelope: envelope() });
    ca.send({ type: "send", id: id2, chatId: chat.id, envelope: envelope() });
    const ack1 = await ca.next("ack");
    const ack2 = await ca.next("ack");
    expect([ack1.id, ack1.seq, ack2.id, ack2.seq]).toEqual([id1, 1, id2, 2]);
    const m1 = (await cb.next("msg")).message as Record<string, unknown>;
    const m2 = (await cb.next("msg")).message as Record<string, unknown>;
    expect(m1).toMatchObject({ chatId: chat.id, seq: 1, id: id1, senderUserId: a.userId, senderDeviceId: a.deviceId, envelope: envelope() });
    expect(m2.seq).toBe(2);
    await cs.none("msg");
    await ca.none("msg");
    const stored = await (await api(b.accessToken, "GET", `/chats/${chat.id}/messages`)).json<{ messages: unknown[] }>();
    expect(stored.messages).toHaveLength(2);
    const c = (await (await api(a.accessToken, "GET", `/chats/${chat.id}`)).json<{ chat: ChatOut }>()).chat;
    expect(c.lastSeq).toBe(2);
    expect(c.lastMessageAt).toBe(ack2.createdAt);
  });

  it("the sender's other device receives the message", async () => {
    const a = await insertUserWithDevice();
    const b = await insertUserWithDevice();
    const chat = await createDirect(a, b);
    const ca = await connect(a);
    const ca2 = await connect(a);
    const id = newId();
    ca.send({ type: "send", id, chatId: chat.id, envelope: envelope() });
    await ca.next("ack");
    expect(((await ca2.next("msg")).message as { id: string }).id).toBe(id);
  });

  it("a send to a direct chat with no shared family is refused", async () => {
    const f3 = await insertFamily();
    const a = await insertUserWithDevice({ families: [{ id: f3 }] });
    const b = await insertUserWithDevice({ families: [{ id: f3 }] });
    const chat = await createDirect(a, b);
    await env.DB.prepare("DELETE FROM family_members WHERE family_id = ? AND user_id = ?").bind(f3, b.userId).run();
    const ca = await connect(a);
    const cb = await connect(b);
    const id = newId();
    ca.send({ type: "send", id, chatId: chat.id, envelope: envelope() });
    expect(await ca.next("error")).toEqual({ type: "error", id, error: "no_shared_family" });
    await cb.none("msg");
    expect(await env.DB.prepare("SELECT COUNT(*) AS n FROM messages WHERE chat_id = ?").bind(chat.id).first("n")).toBe(0);
  });

  it("a direct chat whose peer deleted their account still takes sends", async () => {
    const a = await insertUserWithDevice();
    const b = await insertUserWithDevice();
    const chat = await createDirect(a, b);
    await env.DB.batch([
      env.DB.prepare("UPDATE users SET deleted_at = ? WHERE id = ?").bind(Date.now(), b.userId),
      env.DB.prepare("DELETE FROM chat_members WHERE chat_id = ? AND user_id = ?").bind(chat.id, b.userId),
    ]);
    const ca = await connect(a);
    const id = newId();
    ca.send({ type: "send", id, chatId: chat.id, envelope: envelope() });
    expect(await ca.next("ack")).toMatchObject({ id, seq: 1 });
  });

  it("resending an id acks the original seq without a second row or fan-out", async () => {
    const a = await insertUserWithDevice();
    const b = await insertUserWithDevice();
    const chat = await createDirect(a, b);
    const ca = await connect(a);
    const cb = await connect(b);
    const id = newId();
    ca.send({ type: "send", id, chatId: chat.id, envelope: envelope() });
    const first = await ca.next("ack");
    await cb.next("msg");
    ca.send({ type: "send", id, chatId: chat.id, envelope: envelope() });
    const again = await ca.next("ack");
    expect(again).toEqual(first);
    await cb.none("msg");
    const n = await env.DB.prepare("SELECT COUNT(*) AS n FROM messages").first<number>("n");
    expect(n).toBe(1);
  });

  it("an id reused in another chat is a conflict", async () => {
    const a = await insertUserWithDevice();
    const b = await insertUserWithDevice();
    const one = await createDirect(a, b);
    const two = await createGroup(a, [b]);
    const ca = await connect(a);
    const id = newId();
    ca.send({ type: "send", id, chatId: one.id, envelope: envelope() });
    await ca.next("ack");
    ca.send({ type: "send", id, chatId: two.id, envelope: envelope() });
    expect(await ca.next("error")).toEqual({ type: "error", id, error: "conflict" });
  });

  it("a non-member's send is refused", async () => {
    const a = await insertUserWithDevice();
    const b = await insertUserWithDevice();
    const chat = await createDirect(a, b);
    const cs = await connect(await insertUserWithDevice());
    const id = newId();
    cs.send({ type: "send", id, chatId: chat.id, envelope: envelope() });
    expect(await cs.next("error")).toEqual({ type: "error", id, error: "not_member" });
  });

  it("send with an old epoch is refused", async () => {
    const a = await insertUserWithDevice();
    const b = await insertUserWithDevice();
    const c = await insertUserWithDevice();
    const chat = await createGroup(a, [b, c]);
    await api(c.accessToken, "DELETE", `/chats/${chat.id}/members/${c.userId}`);
    const ca = await connect(a);
    const id = newId();
    ca.send({ type: "send", id, chatId: chat.id, envelope: envelope(1) });
    expect(await ca.next("error")).toEqual({ type: "error", id, error: "stale_epoch" });
    // Epoch 2 is not created yet either.
    ca.send({ type: "send", id, chatId: chat.id, envelope: envelope(2) });
    expect(await ca.next("error")).toEqual({ type: "error", id, error: "stale_epoch" });
    await api(a.accessToken, "POST", `/chats/${chat.id}/epochs`, {
      epoch: 2, wraps: wrapsFor(chat.id, 2, a.deviceId, [a.deviceId, b.deviceId]),
    });
    ca.send({ type: "send", id, chatId: chat.id, envelope: envelope(2) });
    expect((await ca.next("ack")).seq).toBe(1);
  });

  it("a malformed send is refused", async () => {
    const a = await insertUserWithDevice();
    const b = await insertUserWithDevice();
    const chat = await createDirect(a, b);
    const ca = await connect(a);
    const id = newId();
    for (const bad of [
      { type: "send", id, chatId: chat.id, envelope: { ...envelope(), v: 2 } },
      { type: "send", id, chatId: chat.id, envelope: { ...envelope(), ct: "not base64!" } },
      { type: "send", id, chatId: chat.id, envelope: { ...envelope(), ct: "A".repeat(70_000) } },
      { type: "send", id: "nope", chatId: chat.id, envelope: envelope() },
      { type: "send", id, chatId: chat.id },
      { type: "bogus" },
    ]) {
      ca.send(bad);
      expect((await ca.next("error")).error).toBe("invalid_request");
    }
    ca.ws.send("not json");
    expect((await ca.next("error")).error).toBe("invalid_request");
  });

  it("devices with a push token and no open socket are passed to the push hook", async () => {
    const a = await insertUserWithDevice();
    const b = await insertUserWithDevice();
    const c = await insertUserWithDevice();
    const chat = await createGroup(a, [b, c]);
    for (const u of [a, b, c]) await setPushToken(u.deviceId, `tok-${u.deviceId}`);
    const jobs: PushJob[] = [];
    await runInDurableObject(env.HUB.get(env.HUB.idFromName("family")), (hub: FamilyHub) => {
      hub.push = { notify: async (j) => void jobs.push(j) };
    });
    const ca = await connect(a);
    await connect(b);
    const id = newId();
    ca.send({ type: "send", id, chatId: chat.id, envelope: envelope() });
    await ca.next("ack");
    for (let i = 0; i < 50 && jobs.length === 0; i++) await new Promise((r) => setTimeout(r, 10));
    expect(jobs).toEqual([{ chatId: chat.id, senderUserId: a.userId, messageId: id, userIds: [c.userId], deviceIds: [c.deviceId] }]);
  });

  it("a phone is pushed even while the same user's desktop is connected", async () => {
    const a = await insertUserWithDevice();
    const b = await insertUserWithDevice();
    const bPhone = await addDevice(b.userId);
    const bOld = await addDevice(b.userId); // no token: nothing to push to
    await setPushToken(bPhone, "b-phone");
    await setPushToken(b.deviceId, "b-desktop");
    const chat = await createGroup(a, [b], "Family", [bPhone, bOld]);
    const jobs: PushJob[] = [];
    await runInDurableObject(env.HUB.get(env.HUB.idFromName("family")), (hub: FamilyHub) => {
      hub.push = { notify: async (j) => void jobs.push(j) };
    });
    const ca = await connect(a);
    const cb = await connect(b); // b's desktop (b.deviceId) is online
    const id = newId();
    ca.send({ type: "send", id, chatId: chat.id, envelope: envelope() });
    await ca.next("ack");
    await cb.next("msg");
    for (let i = 0; i < 50 && jobs.length === 0; i++) await new Promise((r) => setTimeout(r, 10));
    expect(jobs).toEqual([{ chatId: chat.id, senderUserId: a.userId, messageId: id, userIds: [b.userId], deviceIds: [bPhone] }]);
  });

  it("no job when every token-holding device is connected", async () => {
    const a = await insertUserWithDevice();
    const b = await insertUserWithDevice();
    await setPushToken(b.deviceId, "b");
    const chat = await createDirect(a, b);
    const jobs: PushJob[] = [];
    await runInDurableObject(env.HUB.get(env.HUB.idFromName("family")), (hub: FamilyHub) => {
      hub.push = { notify: async (j) => void jobs.push(j) };
    });
    const ca = await connect(a);
    const cb = await connect(b);
    ca.send({ type: "send", id: newId(), chatId: chat.id, envelope: envelope() });
    await cb.next("msg");
    await new Promise((r) => setTimeout(r, 100));
    expect(jobs).toEqual([]);
  });

  it("a silent send fans out marked silent and pushes no one", async () => {
    const a = await insertUserWithDevice();
    const b = await insertUserWithDevice();
    const c = await insertUserWithDevice();
    await setPushToken(c.deviceId, "c");
    const chat = await createGroup(a, [b, c]);
    const jobs: PushJob[] = [];
    await runInDurableObject(env.HUB.get(env.HUB.idFromName("family")), (hub: FamilyHub) => {
      hub.push = { notify: async (j) => void jobs.push(j) };
    });
    const ca = await connect(a);
    const cb = await connect(b);
    const before = await env.DB.prepare("SELECT last_message_at FROM chats WHERE id = ?").bind(chat.id).first<number>("last_message_at");
    ca.send({ type: "send", id: newId(), chatId: chat.id, envelope: envelope(), silent: true });
    await ca.next("ack");
    expect((await cb.next("msg")).silent).toBe(true);
    // A silent change doesn't count as chat activity (the list order stays put).
    expect(await env.DB.prepare("SELECT last_message_at FROM chats WHERE id = ?").bind(chat.id).first<number>("last_message_at"))
      .toBe(before);
    ca.send({ type: "send", id: newId(), chatId: chat.id, envelope: envelope() });
    expect((await cb.next("msg")).silent).toBeUndefined();
    for (let i = 0; i < 50 && jobs.length === 0; i++) await new Promise((r) => setTimeout(r, 10));
    expect(jobs.length).toBe(1); // only the second, normal message
  });

  it("members who muted the chat aren't pushed until the mute ends", async () => {
    const a = await insertUserWithDevice();
    const b = await insertUserWithDevice();
    const c = await insertUserWithDevice();
    await setPushToken(b.deviceId, "b");
    await setPushToken(c.deviceId, "c");
    const chat = await createGroup(a, [b, c]);
    expect((await api(b.accessToken, "PUT", `/chats/${chat.id}/mute`, { until: Date.now() + 3_600_000 })).status).toBe(204);
    expect((await api(c.accessToken, "PUT", `/chats/${chat.id}/mute`, { until: Date.now() - 1000 })).status).toBe(204);
    const jobs: PushJob[] = [];
    await runInDurableObject(env.HUB.get(env.HUB.idFromName("family")), (hub: FamilyHub) => {
      hub.push = { notify: async (j) => void jobs.push(j) };
    });
    const ca = await connect(a);
    ca.send({ type: "send", id: newId(), chatId: chat.id, envelope: envelope() });
    await ca.next("ack");
    for (let i = 0; i < 50 && jobs.length === 0; i++) await new Promise((r) => setTimeout(r, 10));
    expect(jobs.map((j) => j.userIds)).toEqual([[c.userId]]);
  });

  it("a mention reaches the mentioned member even when they muted the chat, as its own job", async () => {
    const a = await insertUserWithDevice();
    const b = await insertUserWithDevice();
    const c = await insertUserWithDevice();
    const d = await insertUserWithDevice();
    const outsider = await insertUserWithDevice();
    for (const u of [b, c, d]) await setPushToken(u.deviceId, u.userId);
    const chat = await createGroup(a, [b, c, d]);
    for (const u of [b, d]) {
      expect((await api(u.accessToken, "PUT", `/chats/${chat.id}/mute`, { until: Date.now() + 3_600_000 })).status).toBe(204);
    }
    const jobs: PushJob[] = [];
    await runInDurableObject(env.HUB.get(env.HUB.idFromName("family")), (hub: FamilyHub) => {
      hub.push = { notify: async (j) => void jobs.push(j) };
    });
    const ca = await connect(a);
    const id = newId();
    // Mentioning yourself, a non-member or junk changes nothing.
    ca.send({
      type: "send", id, chatId: chat.id, envelope: envelope(),
      mentions: [b.userId, a.userId, outsider.userId, "x", b.userId],
    });
    await ca.next("ack");
    for (let i = 0; i < 50 && jobs.length < 2; i++) await new Promise((r) => setTimeout(r, 10));
    expect(jobs.length).toBe(2);
    const byKind = Object.fromEntries(jobs.map((j) => [j.mention ? "mention" : "plain", j.userIds]));
    expect(byKind).toEqual({ mention: [b.userId], plain: [c.userId] });
  });

  it("msg frames carry the mentions of members, for notifications before decryption", async () => {
    const a = await insertUserWithDevice();
    const b = await insertUserWithDevice();
    const c = await insertUserWithDevice();
    const chat = await createGroup(a, [b, c]);
    const ca = await connect(a);
    const cb = await connect(b);
    ca.send({ type: "send", id: newId(), chatId: chat.id, envelope: envelope(), mentions: [b.userId, newId()] });
    expect((await cb.next("msg")).mentions).toEqual([b.userId]);
    ca.send({ type: "send", id: newId(), chatId: chat.id, envelope: envelope() });
    expect((await cb.next("msg")).mentions).toBeUndefined();
  });

  it("a mention list that isn't a short list of ids is refused", async () => {
    const a = await insertUserWithDevice();
    const b = await insertUserWithDevice();
    const chat = await createGroup(a, [b]);
    const ca = await connect(a);
    for (const mentions of ["x", [1], Array.from({ length: 51 }, () => newId())]) {
      const id = newId();
      ca.send({ type: "send", id, chatId: chat.id, envelope: envelope(), mentions });
      expect((await ca.next("error")).error).toBe("invalid_request");
    }
  });

  it("muting tells the user's own sockets the chat changed", async () => {
    const a = await insertUserWithDevice();
    const b = await insertUserWithDevice();
    const chat = await createDirect(a, b);
    const ca = await connect(a);
    const cb = await connect(b);
    expect((await api(a.accessToken, "PUT", `/chats/${chat.id}/mute`, { until: null })).status).toBe(204);
    expect((await ca.next("chat")).chatId).toBe(chat.id);
    await cb.none("chat");
  });

  it("a socket silent for over a minute is pruned and its user pushed", async () => {
    const a = await insertUserWithDevice();
    const b = await insertUserWithDevice();
    const c = await insertUserWithDevice();
    const chat = await createGroup(a, [b, c]);
    for (const u of [b, c]) await setPushToken(u.deviceId, `tok-${u.deviceId}`);
    const ca = await connect(a);
    const cb = await connect(b);
    const cc = await connect(c);
    // b answers pings; c went quiet (a phone that lost its network). Both connected long ago.
    cb.send({ type: "ping" });
    await cb.next("pong");
    const stub = env.HUB.get(env.HUB.idFromName("family"));
    const jobs: PushJob[] = [];
    await runInDurableObject(stub, (hub: FamilyHub, state) => {
      hub.push = { notify: async (j) => void jobs.push(j) };
      for (const ws of [...state.getWebSockets(`d:${b.deviceId}`), ...state.getWebSockets(`d:${c.deviceId}`)]) {
        ws.serializeAttachment({ ...(ws.deserializeAttachment() as object), at: Date.now() - STALE_SOCKET_MS - 1000 });
      }
    });
    const id = newId();
    ca.send({ type: "send", id, chatId: chat.id, envelope: envelope() });
    await ca.next("ack");
    expect(await cc.closed).toBe(4002);
    expect(await cb.next("presence")).toEqual({ type: "presence", userId: c.userId, online: true }); // c joining
    expect(await cb.next("presence")).toEqual({ type: "presence", userId: c.userId, online: false });
    await cb.next("msg");
    for (let i = 0; i < 50 && jobs.length === 0; i++) await new Promise((r) => setTimeout(r, 10));
    expect(jobs).toEqual([{ chatId: chat.id, senderUserId: a.userId, messageId: id, userIds: [c.userId], deviceIds: [c.deviceId] }]);
  });

  it("the default push hook puts the job on the queue", async () => {
    const sent: PushJob[] = [];
    const job = { chatId: "c", senderUserId: "s", messageId: "m", userIds: ["u"] };
    await queuePush({ PUSH_QUEUE: { send: async (j: PushJob) => void sent.push(j) } as unknown as Queue<PushJob> }).notify(job);
    expect(sent).toEqual([job]);
    // No binding: push is off, nothing throws.
    await queuePush({}).notify(job);
  });
});

describe("typing and read receipts", () => {
  it("typing reaches other members only", async () => {
    const a = await insertUserWithDevice();
    const b = await insertUserWithDevice();
    const chat = await createDirect(a, b);
    const ca = await connect(a);
    const ca2 = await connect(a);
    const cb = await connect(b);
    const cs = await connect(await insertUserWithDevice());
    ca.send({ type: "typing", chatId: chat.id });
    expect(await cb.next("typing")).toEqual({ type: "typing", chatId: chat.id, userId: a.userId });
    await ca2.none("typing");
    await cs.none("typing");
    cs.send({ type: "typing", chatId: chat.id });
    await cb.none("typing");
  });

  it("read updates last_read_seq, never backwards, and broadcasts", async () => {
    const a = await insertUserWithDevice();
    const b = await insertUserWithDevice();
    const chat = await createDirect(a, b);
    const ca = await connect(a);
    const cb = await connect(b);
    const cb2 = await connect(b);
    for (let i = 0; i < 3; i++) {
      ca.send({ type: "send", id: newId(), chatId: chat.id, envelope: envelope() });
      await ca.next("ack");
    }
    cb.send({ type: "read", chatId: chat.id, seq: 2 });
    expect(await ca.next("read")).toEqual({ type: "read", chatId: chat.id, userId: b.userId, seq: 2 });
    expect((await cb2.next("read")).seq).toBe(2);
    cb.send({ type: "read", chatId: chat.id, seq: 1 });
    await ca.none("read");
    cb.send({ type: "read", chatId: chat.id, seq: 99 });
    expect((await ca.next("read")).seq).toBe(3);
    const c = (await (await api(a.accessToken, "GET", `/chats/${chat.id}`)).json<{ chat: ChatOut }>()).chat;
    expect(c.members.find((m) => m.userId === b.userId)!.lastReadSeq).toBe(3);
  });
});

describe("events from REST", () => {
  it("creating a chat notifies members", async () => {
    const a = await insertUserWithDevice();
    const b = await insertUserWithDevice();
    const cb = await connect(b);
    const cs = await connect(await insertUserWithDevice());
    const chat = await createGroup(a, [b]);
    expect(await cb.next("chat")).toEqual({ type: "chat", chatId: chat.id });
    await cs.none("chat");
  });

  it("leaving sends removed to the leaver and chat to the rest", async () => {
    const a = await insertUserWithDevice();
    const b = await insertUserWithDevice();
    const chat = await createGroup(a, [b]);
    const ca = await connect(a);
    const cb = await connect(b);
    await api(b.accessToken, "DELETE", `/chats/${chat.id}/members/${b.userId}`);
    expect(await cb.next("removed")).toEqual({ type: "removed", chatId: chat.id });
    expect(await ca.next("chat")).toEqual({ type: "chat", chatId: chat.id });
  });

  it("repair wraps notify the recipient with keys", async () => {
    const a = await insertUserWithDevice();
    const b = await insertUserWithDevice();
    const chat = await createGroup(a, [b]);
    const cb = await connect(b);
    await env.DB.prepare("DELETE FROM chat_key_wraps WHERE device_id = ?").bind(b.deviceId).run();
    await api(a.accessToken, "PUT", "/keys/wraps", { wraps: wrapsFor(chat.id, 1, a.deviceId, [b.deviceId]) });
    expect(await cb.next("keys")).toEqual({ type: "keys", chatId: chat.id });
  });

  it("revoking a device closes its socket", async () => {
    const a = await insertUserWithDevice();
    const ca = await connect(a);
    expect((await api(a.accessToken, "DELETE", `/devices/${a.deviceId}`)).status).toBe(204);
    expect(await ca.closed).toBe(4001);
  });
});

describe("family scope", () => {
  const hub = () => env.HUB.get(env.HUB.idFromName("family"));
  const leaveFamily = (userId: string, familyId: number) =>
    env.DB.prepare("DELETE FROM family_members WHERE family_id = ? AND user_id = ?").bind(familyId, userId).run();

  it("hello and presence reach only people sharing a family", async () => {
    const f3 = await insertFamily();
    const a = await insertUserWithDevice();
    const b = await insertUserWithDevice();
    const c = await insertUserWithDevice({ families: [{ id: f3 }] });
    const ca = await connect(a);
    await ca.next("hello");
    const cc = await connect(c);
    expect((await cc.next("hello")).online).toEqual([c.userId]);
    await ca.none("presence");
    const cb = await connect(b);
    expect(((await cb.next("hello")).online as string[]).sort()).toEqual([a.userId, b.userId].sort());
    expect(await ca.next("presence")).toEqual({ type: "presence", userId: b.userId, online: true });
    await cc.none("presence");
    cc.ws.close(1000, "bye");
    await ca.none("presence");
    await cb.none("presence");
  });

  it("a newcomer's presence reaches connected people without reconnecting", async () => {
    const a = await insertUserWithDevice({ admin: true });
    const ca = await connect(a);
    await ca.next("hello");
    const b = await redeemNewDevice();
    const cb = await connect(b as unknown as TestUser);
    expect((await cb.next("hello")).online).toEqual(expect.arrayContaining([a.userId, b.userId]));
    expect(await ca.next("presence")).toEqual({ type: "presence", userId: b.userId, online: true });
    // A's cached peer set predates B: redeeming must have cleared it.
    const chat = await createDirect(a, b as unknown as TestUser);
    ca.send({ type: "typing", chatId: chat.id });
    expect(await cb.next("typing")).toEqual({ type: "typing", chatId: chat.id, userId: a.userId });
  });

  it("typing in a shared direct chat stops when the two share no family", async () => {
    const f3 = await insertFamily();
    const a = await insertUserWithDevice({ families: [{ id: f3 }] });
    const b = await insertUserWithDevice({ families: [{ id: f3 }] });
    const chat = await createDirect(a, b);
    const ca = await connect(a);
    const cb = await connect(b);
    ca.send({ type: "typing", chatId: chat.id });
    expect(await cb.next("typing")).toEqual({ type: "typing", chatId: chat.id, userId: a.userId });
    await leaveFamily(b.userId, f3);
    await hub().sharesChanged();
    ca.send({ type: "typing", chatId: chat.id });
    await cb.none("typing");
    cb.send({ type: "typing", chatId: chat.id });
    await ca.none("typing");
  });

  it("profile, reset and account_deleted go only to family peers", async () => {
    const f3 = await insertFamily();
    const a = await insertUserWithDevice();
    const c = await insertUserWithDevice({ families: [{ id: f3 }] });
    const d = await insertUserWithDevice({ families: [{ id: f3 }] });
    const ca = await connect(a);
    const cc = await connect(c);
    const cd = await connect(d);
    expect((await api(c.accessToken, "PUT", "/me/name", { name: "Cee" })).status).toBe(204);
    expect(await cc.next("profile")).toEqual({ type: "profile", userId: c.userId });
    expect(await cd.next("profile")).toEqual({ type: "profile", userId: c.userId });
    await ca.none("profile");

    await notifyReset(env, c.userId, "r1");
    expect(await cd.next("reset")).toEqual({ type: "reset", userId: c.userId, resetId: "r1" });
    await ca.none("reset");

    expect((await api(c.accessToken, "DELETE", "/me", { confirm: "delete" })).status).toBe(204);
    expect(await cd.next("account_deleted")).toEqual({ type: "account_deleted", userId: c.userId });
    await ca.none("account_deleted");
  });

  it("device events skip former chat partners", async () => {
    const f3 = await insertFamily();
    const a = await insertUserWithDevice({ families: [{ id: f3 }] });
    const b = await insertUserWithDevice({ families: [{ id: f3 }] });
    const c = await insertUserWithDevice({ families: [{ id: f3 }] });
    await createGroup(a, [b, c]);
    await leaveFamily(b.userId, f3);
    await hub().sharesChanged();
    const cb = await connect(b);
    const cc = await connect(c);
    const extra = await addDevice(a.userId);
    expect((await api(a.accessToken, "DELETE", `/devices/${extra}`)).status).toBe(204);
    expect(await cc.next("device")).toEqual({ type: "device", userId: a.userId, deviceId: extra, revoked: true });
    await cb.none("device");
  });

  it("deleting an account clears the peer cache", async () => {
    const a = await insertUserWithDevice();
    const b = await insertUserWithDevice();
    const ca = await connect(a);
    await ca.next("hello");
    const peers = (h: FamilyHub) => (h as unknown as { peers: Map<string, Set<string>> }).peers;
    expect(await runInDurableObject(hub(), (h: FamilyHub) => peers(h).get(a.userId)?.has(b.userId))).toBe(true);
    expect((await api(b.accessToken, "DELETE", "/me", { confirm: "delete" })).status).toBe(204);
    expect(await runInDurableObject(hub(), (h: FamilyHub) => peers(h).has(a.userId))).toBe(false);
  });
});
