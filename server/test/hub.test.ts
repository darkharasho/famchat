import { env, runInDurableObject, SELF } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { type FamilyHub, type PushJob, queuePush, STALE_SOCKET_MS } from "../src/hub";
import { newId } from "../src/lib/ids";
import { addDevice, api, type ChatOut, createDirect, createGroup, type TestUser, wrapsFor } from "./chat-helpers";
import { BASE, insertUserWithDevice, resetDb } from "./helpers";

type Msg = Record<string, unknown> & { type: string };

interface Client {
  ws: WebSocket;
  send(m: unknown): void;
  next(type: string, timeoutMs?: number): Promise<Msg>;
  none(type: string, waitMs?: number): Promise<void>;
  closed: Promise<number>;
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
  let wake: (() => void) | null = null;
  ws.addEventListener("message", (e) => {
    inbox.push(JSON.parse(e.data as string) as Msg);
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
});

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
