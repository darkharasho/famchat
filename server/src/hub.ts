// FamilyHub: the one Durable Object for the family. Every device keeps one WebSocket to it.
// It sequences and fans out messages, relays typing/read/presence, and receives events from REST
// routes over RPC. Uses the hibernation API, so an idle family costs almost nothing.
import { DurableObject } from "cloudflare:workers";
import type { Env } from "./env";
import { isUlid } from "./lib/chatdb";
import { evictOldest } from "./lib/media";
import { messageOut } from "./lib/messages";

/** A message for members with no open socket. Plan 9 turns this into a Queue job for FCM. */
export interface PushJob {
  chatId: string;
  senderUserId: string;
  messageId: string;
  userIds: string[];
}

export interface PushHook {
  notify(job: PushJob): Promise<void>;
}

export const noPush: PushHook = { notify: async () => {} };

type Att = { userId: string; deviceId: string };
type Incoming = Record<string, unknown>;

export const MAX_ENVELOPE_BYTES = 64 * 1024;
const B64URL = /^[A-Za-z0-9_-]+$/;

export function hubStub(env: Env) {
  return env.HUB.get(env.HUB.idFromName("family"));
}

export class FamilyHub extends DurableObject<Env> {
  /** Replaced in plan 9 (and in tests). */
  push: PushHook = noPush;

  /** Sends run one at a time, so seqs are handed out and fanned out in order. */
  private sends: Promise<void> = Promise.resolve();

  /** Media evictions run one at a time, so two uploads past the cap never both evict. */
  private evictions: Promise<unknown> = Promise.resolve();

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair('{"type":"ping"}', '{"type":"pong"}'));
  }

  /** Called by the Worker's /api/ws route after it checked the ticket. */
  async fetch(req: Request): Promise<Response> {
    const userId = req.headers.get("x-famchat-user");
    const deviceId = req.headers.get("x-famchat-device");
    if (!userId || !deviceId || req.headers.get("upgrade")?.toLowerCase() !== "websocket") {
      return new Response("bad request", { status: 400 });
    }
    const [client, server] = Object.values(new WebSocketPair());
    const wasOnline = this.sockets(userId).length > 0;
    this.ctx.acceptWebSocket(server, [`u:${userId}`, `d:${deviceId}`]);
    server.serializeAttachment({ userId, deviceId } satisfies Att);
    server.send(JSON.stringify({ type: "hello", online: this.onlineUserIds() }));
    if (!wasOnline) this.sendAll({ type: "presence", userId, online: true }, server);
    return new Response(null, { status: 101, webSocket: client });
  }

  async webSocketMessage(ws: WebSocket, raw: string | ArrayBuffer): Promise<void> {
    const att = ws.deserializeAttachment() as Att;
    let m: Incoming;
    try {
      const parsed = JSON.parse(typeof raw === "string" ? raw : new TextDecoder().decode(raw));
      if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) throw new Error("not an object");
      m = parsed as Incoming;
    } catch {
      return send(ws, { type: "error", error: "invalid_request" });
    }
    switch (m.type) {
      case "send": {
        const run = this.sends.then(() => this.handleSend(ws, att, m));
        this.sends = run.catch((e) => console.error("send failed", e));
        return run.catch(() => send(ws, { type: "error", id: typeof m.id === "string" ? m.id : undefined, error: "internal" }));
      }
      case "typing":
        return this.handleTyping(att, m);
      case "read":
        return this.handleRead(att, m);
      default:
        return send(ws, { type: "error", error: "invalid_request" });
    }
  }

  async webSocketClose(ws: WebSocket, code: number, reason: string): Promise<void> {
    try {
      ws.close(code === 1005 || code === 1006 ? 1000 : code, reason);
    } catch {
      /* already closed */
    }
    this.goneOffline(ws);
  }

  async webSocketError(ws: WebSocket): Promise<void> {
    this.goneOffline(ws);
  }

  // --- RPC from the Worker ---

  /** Sends [event] to every open socket of [userIds]. */
  async notify(userIds: string[], event: Record<string, unknown>): Promise<void> {
    const text = JSON.stringify(event);
    for (const u of new Set(userIds)) for (const ws of this.sockets(u)) trySend(ws, text);
  }

  /** Closes a revoked device's sockets. */
  async disconnectDevice(deviceId: string): Promise<void> {
    for (const ws of this.ctx.getWebSockets(`d:${deviceId}`)) {
      try {
        ws.close(4001, "device revoked");
      } catch {
        /* already closed */
      }
      this.goneOffline(ws);
    }
  }

  /** Expires the oldest media while the family is over the cap; returns how many objects. */
  async evictMedia(): Promise<number> {
    const run = this.evictions.then(() => evictOldest(this.env, (userIds, event) => this.notify(userIds, event)));
    this.evictions = run.catch(() => {});
    return (await run).length;
  }

  onlineUserIds(exclude?: WebSocket): string[] {
    const ids = new Set<string>();
    for (const ws of this.ctx.getWebSockets()) {
      if (ws === exclude || ws.readyState !== WebSocket.READY_STATE_OPEN) continue;
      const att = ws.deserializeAttachment() as Att | null;
      if (att) ids.add(att.userId);
    }
    return [...ids];
  }

  // --- internals ---

  private sockets(userId: string, exclude?: WebSocket): WebSocket[] {
    return this.ctx.getWebSockets(`u:${userId}`).filter(
      (ws) => ws !== exclude && ws.readyState === WebSocket.READY_STATE_OPEN,
    );
  }

  private sendAll(event: Record<string, unknown>, exclude?: WebSocket): void {
    const text = JSON.stringify(event);
    for (const ws of this.ctx.getWebSockets()) if (ws !== exclude) trySend(ws, text);
  }

  private goneOffline(ws: WebSocket): void {
    const att = ws.deserializeAttachment() as Att | null;
    if (!att) return;
    // Only once per socket: a revoked socket is seen here and again in webSocketClose.
    ws.serializeAttachment(null);
    if (this.sockets(att.userId, ws).length === 0) {
      this.sendAll({ type: "presence", userId: att.userId, online: false }, ws);
    }
  }

  private async memberIds(chatId: string): Promise<string[]> {
    const { results } = await this.env.DB.prepare("SELECT user_id FROM chat_members WHERE chat_id = ?")
      .bind(chatId).all<{ user_id: string }>();
    return results.map((r) => r.user_id);
  }

  private async handleSend(ws: WebSocket, att: Att, m: Incoming): Promise<void> {
    const id = m.id;
    const chatId = m.chatId;
    const env = m.envelope;
    if (!isUlid(id) || typeof chatId !== "string" || !validEnvelope(env)) {
      return send(ws, { type: "error", id: typeof id === "string" ? id : undefined, error: "invalid_request" });
    }
    const db = this.env.DB;
    const prior = await db.prepare("SELECT chat_id, seq, sender_device_id, created_at FROM messages WHERE id = ?")
      .bind(id).first<{ chat_id: string; seq: number; sender_device_id: string; created_at: number }>();
    if (prior) {
      if (prior.chat_id === chatId && prior.sender_device_id === att.deviceId) {
        return send(ws, { type: "ack", id, seq: prior.seq, createdAt: prior.created_at });
      }
      return send(ws, { type: "error", id, error: "conflict" });
    }
    const chat = await db.prepare(
      `SELECT c.current_epoch,
         EXISTS (SELECT 1 FROM chat_epochs e WHERE e.chat_id = c.id AND e.epoch = c.current_epoch) AS ready
       FROM chats c JOIN chat_members m ON m.chat_id = c.id AND m.user_id = ? WHERE c.id = ?`,
    ).bind(att.userId, chatId).first<{ current_epoch: number; ready: number }>();
    if (!chat) return send(ws, { type: "error", id, error: "not_member" });
    if (env.epoch !== chat.current_epoch || chat.ready !== 1) return send(ws, { type: "error", id, error: "stale_epoch" });

    const now = Date.now();
    const [, inserted] = await db.batch([
      db.prepare("UPDATE chats SET last_seq = last_seq + 1, last_message_at = ? WHERE id = ?").bind(now, chatId),
      db.prepare(
        `INSERT INTO messages (chat_id, seq, id, sender_user_id, sender_device_id, envelope, created_at)
         SELECT id, last_seq, ?, ?, ?, ?, ? FROM chats WHERE id = ? RETURNING seq`,
      ).bind(id, att.userId, att.deviceId, JSON.stringify(env), now, chatId),
    ]);
    const seq = (inserted.results[0] as { seq: number }).seq;
    send(ws, { type: "ack", id, seq, createdAt: now });

    const msg = JSON.stringify({
      type: "msg",
      message: messageOut({
        chat_id: chatId, seq, id, sender_user_id: att.userId, sender_device_id: att.deviceId,
        envelope: JSON.stringify(env), created_at: now,
      }),
    });
    const offline: string[] = [];
    for (const u of await this.memberIds(chatId)) {
      const socks = this.sockets(u, ws);
      for (const s of socks) trySend(s, msg);
      if (u !== att.userId && this.sockets(u).length === 0) offline.push(u);
    }
    if (offline.length) {
      try {
        await this.push.notify({ chatId, senderUserId: att.userId, messageId: id, userIds: offline });
      } catch (e) {
        console.error("push hook failed", e);
      }
    }
  }

  private async handleTyping(att: Att, m: Incoming): Promise<void> {
    if (typeof m.chatId !== "string") return;
    const members = await this.memberIds(m.chatId);
    if (!members.includes(att.userId)) return;
    const text = JSON.stringify({ type: "typing", chatId: m.chatId, userId: att.userId });
    for (const u of members) if (u !== att.userId) for (const s of this.sockets(u)) trySend(s, text);
  }

  private async handleRead(att: Att, m: Incoming): Promise<void> {
    if (typeof m.chatId !== "string" || !Number.isInteger(m.seq) || (m.seq as number) < 0) return;
    const row = await this.env.DB.prepare(
      `UPDATE chat_members SET last_read_seq = MIN(?, (SELECT last_seq FROM chats WHERE id = ?))
       WHERE chat_id = ? AND user_id = ? AND last_read_seq < MIN(?, (SELECT last_seq FROM chats WHERE id = ?))
       RETURNING last_read_seq`,
    ).bind(m.seq, m.chatId, m.chatId, att.userId, m.seq, m.chatId).first<{ last_read_seq: number }>();
    if (!row) return;
    await this.notify(await this.memberIds(m.chatId), {
      type: "read", chatId: m.chatId, userId: att.userId, seq: row.last_read_seq,
    });
  }
}

function validEnvelope(e: unknown): e is { v: 1; epoch: number; nonce: string; ct: string; sig: string } {
  if (!e || typeof e !== "object" || Array.isArray(e)) return false;
  const o = e as Record<string, unknown>;
  if (o.v !== 1 || !Number.isInteger(o.epoch) || (o.epoch as number) < 1) return false;
  for (const k of ["nonce", "ct", "sig"]) if (typeof o[k] !== "string" || !B64URL.test(o[k] as string)) return false;
  return JSON.stringify(o).length <= MAX_ENVELOPE_BYTES;
}

function send(ws: WebSocket, m: Record<string, unknown>): void {
  trySend(ws, JSON.stringify(m));
}

function trySend(ws: WebSocket, text: string): void {
  try {
    ws.send(text);
  } catch {
    /* closing */
  }
}
