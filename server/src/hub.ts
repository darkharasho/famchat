// FamilyHub: the one Durable Object for the family. Every device keeps one WebSocket to it.
// It sequences and fans out messages, relays typing/read/presence, and receives events from REST
// routes over RPC. Uses the hibernation API, so an idle family costs almost nothing.
import { DurableObject } from "cloudflare:workers";
import type { Env } from "./env";
import { isUlid } from "./lib/chatdb";
import { evictOldest } from "./lib/media";
import { messageOut } from "./lib/messages";

/** A message for members with no open socket: a job on the push queue (src/push/consumer.ts). */
export interface PushJob {
  chatId: string;
  senderUserId: string;
  messageId: string;
  userIds: string[];
  /** A retry: only these devices (the rest already got it). */
  deviceIds?: string[];
  /** 0 for the first try. */
  attempt?: number;
  /** These users were @mentioned: "<sender> mentioned you". */
  mention?: boolean;
}

export interface PushHook {
  notify(job: PushJob): Promise<void>;
}

/** At most this many @mentions per message (a family is smaller). */
export const MAX_MENTIONS = 50;

export const noPush: PushHook = { notify: async () => {} };

/** Puts jobs on the push queue; without the binding (local dev without queues) push is off. */
export function queuePush(env: Pick<Env, "PUSH_QUEUE">): PushHook {
  return {
    notify: async (job) => {
      if (env.PUSH_QUEUE) await env.PUSH_QUEUE.send(job);
    },
  };
}

/**
 * A socket that answered no ping (clients ping every 25 s) for this long is half-open: a phone that
 * lost its network without closing. It is closed so its device counts as offline and gets pushes.
 * Not 60 s: Chrome throttles timers in long-hidden tabs to about once a minute.
 */
export const STALE_SOCKET_MS = 90_000;

/**
 * [at]: when the socket connected (Unix ms). [rv]: a reviewer account's socket; presence never
 * crosses between reviewers and the family (missing on sockets from before reviewers: family).
 */
type Att = { userId: string; deviceId: string; at: number; rv?: boolean };
type Incoming = Record<string, unknown>;

export const MAX_ENVELOPE_BYTES = 64 * 1024;
const B64URL = /^[A-Za-z0-9_-]+$/;

export function hubStub(env: Env) {
  return env.HUB.get(env.HUB.idFromName("family"));
}

export class FamilyHub extends DurableObject<Env> {
  /** Replaced in tests. */
  push: PushHook;

  /** The clock for stale-socket pruning; replaced in tests. */
  now: () => number = Date.now;

  /** Sends run one at a time, so seqs are handed out and fanned out in order. */
  private sends: Promise<void> = Promise.resolve();

  /** Media evictions run one at a time, so two uploads past the cap never both evict. */
  private evictions: Promise<unknown> = Promise.resolve();

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.push = queuePush(env);
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair('{"type":"ping"}', '{"type":"pong"}'));
  }

  /** Called by the Worker's /api/ws route after it checked the ticket. */
  async fetch(req: Request): Promise<Response> {
    const userId = req.headers.get("x-famchat-user");
    const deviceId = req.headers.get("x-famchat-device");
    const rv = req.headers.get("x-famchat-side") === "reviewer";
    if (!userId || !deviceId || req.headers.get("upgrade")?.toLowerCase() !== "websocket") {
      return new Response("bad request", { status: 400 });
    }
    this.prune();
    const [client, server] = Object.values(new WebSocketPair());
    const wasOnline = this.sockets(userId).length > 0;
    this.ctx.acceptWebSocket(server, [`u:${userId}`, `d:${deviceId}`]);
    server.serializeAttachment({ userId, deviceId, at: this.now(), rv } satisfies Att);
    server.send(JSON.stringify({ type: "hello", online: this.onlineUserIds(undefined, rv) }));
    if (!wasOnline) this.sendAll({ type: "presence", userId, online: true }, rv, server);
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

  /** Family membership changed; Task 5 drops cached peer sets here. */
  async sharesChanged(): Promise<void> {}

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

  /** Who is online on one side: the family, or ([reviewer]) the reviewer accounts. */
  onlineUserIds(exclude?: WebSocket, reviewer = false): string[] {
    const ids = new Set<string>();
    for (const ws of this.ctx.getWebSockets()) {
      if (ws === exclude || ws.readyState !== WebSocket.READY_STATE_OPEN) continue;
      const att = ws.deserializeAttachment() as Att | null;
      if (att && !!att.rv === reviewer) ids.add(att.userId);
    }
    return [...ids];
  }

  // --- internals ---

  /** Closes half-open sockets (see [STALE_SOCKET_MS]), except [keep], which just spoke. */
  private prune(keep?: WebSocket): void {
    const cutoff = this.now() - STALE_SOCKET_MS;
    for (const ws of this.ctx.getWebSockets()) {
      if (ws === keep) continue;
      const att = ws.deserializeAttachment() as Att | null;
      if (!att) continue;
      const pinged = this.ctx.getWebSocketAutoResponseTimestamp(ws)?.getTime() ?? 0;
      if (Math.max(pinged, att.at ?? 0) >= cutoff) continue;
      try {
        ws.close(4002, "timeout");
      } catch {
        /* already closed */
      }
      this.goneOffline(ws);
    }
  }

  private sockets(userId: string, exclude?: WebSocket): WebSocket[] {
    return this.ctx.getWebSockets(`u:${userId}`).filter(
      (ws) => ws !== exclude && ws.readyState === WebSocket.READY_STATE_OPEN,
    );
  }

  /** Sends [event] to every socket on one side (family, or [reviewer] accounts). */
  private sendAll(event: Record<string, unknown>, reviewer: boolean, exclude?: WebSocket): void {
    const text = JSON.stringify(event);
    for (const ws of this.ctx.getWebSockets()) {
      if (ws === exclude) continue;
      const att = ws.deserializeAttachment() as Att | null;
      if (att && !!att.rv === reviewer) trySend(ws, text);
    }
  }

  private goneOffline(ws: WebSocket): void {
    const att = ws.deserializeAttachment() as Att | null;
    if (!att) return;
    // Only once per socket: a revoked socket is seen here and again in webSocketClose.
    ws.serializeAttachment(null);
    if (this.sockets(att.userId, ws).length === 0) {
      this.sendAll({ type: "presence", userId: att.userId, online: false }, !!att.rv, ws);
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
    this.prune(ws);
    const mentions = m.mentions;
    const badMentions = mentions !== undefined &&
      !(Array.isArray(mentions) && mentions.length <= MAX_MENTIONS && mentions.every((u) => typeof u === "string"));
    if (!isUlid(id) || typeof chatId !== "string" || !validEnvelope(env) || badMentions) {
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
    // Silent sends (reactions, edits, deletes) reach sockets marked as such, push no one and don't
    // count as chat activity.
    const silent = m.silent === true;
    const [, inserted] = await db.batch([
      db.prepare(
        "UPDATE chats SET last_seq = last_seq + 1, last_message_at = CASE WHEN ? THEN last_message_at ELSE ? END WHERE id = ?",
      ).bind(silent ? 1 : 0, now, chatId),
      db.prepare(
        `INSERT INTO messages (chat_id, seq, id, sender_user_id, sender_device_id, envelope, created_at)
         SELECT id, last_seq, ?, ?, ?, ?, ? FROM chats WHERE id = ? RETURNING seq`,
      ).bind(id, att.userId, att.deviceId, JSON.stringify(env), now, chatId),
    ]);
    const seq = (inserted.results[0] as { seq: number }).seq;
    send(ws, { type: "ack", id, seq, createdAt: now });

    const memberList = await this.memberIds(chatId);
    // Only members other than the sender can be mentioned; silent changes mention no one.
    const mentioned = silent ? [] : [...new Set((mentions as string[] | undefined) ?? [])]
      .filter((u) => u !== att.userId && memberList.includes(u));
    const msg = JSON.stringify({
      type: "msg",
      ...(silent ? { silent: true } : {}),
      ...(mentioned.length ? { mentions: mentioned } : {}),
      message: messageOut({
        chat_id: chatId, seq, id, sender_user_id: att.userId, sender_device_id: att.deviceId,
        envelope: JSON.stringify(env), created_at: now,
      }),
    });
    const others: string[] = [];
    for (const u of memberList) {
      for (const s of this.sockets(u, ws)) trySend(s, msg);
      if (u !== att.userId) others.push(u);
    }
    if (silent) return;
    // Mentioned members get their own job (other text, and it reaches them through a mute).
    const job = { chatId, senderUserId: att.userId, messageId: id };
    // Not awaited: the next send shouldn't wait for the push lookup and the queue.
    this.pushOffline(job, others.filter((u) => !mentioned.includes(u))).catch((e) => console.error("push hook failed", e));
    if (mentioned.length > 0) {
      this.pushOffline({ ...job, mention: true }, mentioned, { throughMute: true }).catch((e) =>
        console.error("push hook failed", e),
      );
    }
  }

  /**
   * Pushes go per device: every device of [userIds] with a push token and no open socket. A phone is
   * pushed even while the same person's desktop app is connected (it may be at home, unwatched).
   */
  private async pushOffline(
    msg: Omit<PushJob, "userIds">,
    userIds: string[],
    { throughMute = false } = {},
  ): Promise<void> {
    if (userIds.length === 0) return;
    // Members who muted the chat until later get no push (unless they were mentioned).
    const { results } = await this.env.DB.prepare(
      `SELECT id, user_id FROM devices WHERE user_id IN (${userIds.map(() => "?").join(",")})
       AND revoked_at IS NULL AND push_token IS NOT NULL
       AND (? OR user_id NOT IN (SELECT user_id FROM chat_members WHERE chat_id = ? AND muted_until > ?)) ORDER BY id`,
    ).bind(...userIds, throughMute ? 1 : 0, msg.chatId, Date.now()).all<{ id: string; user_id: string }>();
    const targets = results.filter((d) =>
      this.ctx.getWebSockets(`d:${d.id}`).every((s) => s.readyState !== WebSocket.READY_STATE_OPEN),
    );
    if (targets.length === 0) return;
    await this.push.notify({
      ...msg,
      userIds: [...new Set(targets.map((d) => d.user_id))],
      deviceIds: targets.map((d) => d.id),
    });
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
