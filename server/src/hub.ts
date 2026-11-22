// FamilyHub: the one Durable Object for the family. Every device keeps one WebSocket to it.
// It sequences and fans out messages, relays typing/read/presence, and receives events from REST
// routes over RPC. Uses the hibernation API, so an idle family costs almost nothing.
// Its one alarm is set to the earliest due item across scheduled messages, reminders and
// disappearing-message deletions (docs/protocol.md "Scheduled messages", "Reminders",
// "Disappearing messages"); it is re-armed after every insert, cancel and run.
import { DurableObject } from "cloudflare:workers";
import type { Env } from "./env";
import { isUlid } from "./lib/chatdb";
import { familyPeers } from "./lib/family";
import { evictOldest } from "./lib/media";
import { messageOut } from "./lib/messages";
import {
  ALL_READ_SQL, BACKSTOP_MS, MAX_ATTEMPTS, retryDelay, TOMBSTONE_KEEP_MS, validAhead,
} from "./lib/timing";

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
  /** The still-encrypted envelope, for devices with previews on to decrypt; absent when too big. */
  preview?: { senderDeviceId: string; epoch: number; envelope: string };
}

/**
 * A quiet app-icon badge update for [userId]'s phones after they read a chat on another device
 * (src/push/consumer.ts works out the number when it sends).
 */
export interface BadgeJob {
  kind: "badge";
  userId: string;
  deviceIds: string[];
  /** 0 for the first try. */
  attempt?: number;
}

/**
 * A reminder [userId] set came due: a push to the devices in [deviceIds] (src/push/consumer.ts),
 * with the message's still-encrypted envelope for previews when small enough.
 */
export interface ReminderJob {
  kind: "reminder";
  userId: string;
  chatId: string;
  messageId: string;
  /** The reminder's time (Unix ms). */
  at: number;
  senderUserId: string;
  deviceIds: string[];
  /** 0 for the first try. */
  attempt?: number;
  preview?: { senderDeviceId: string; epoch: number; envelope: string };
}

/** What goes on the push queue. */
export type QueueJob = PushJob | BadgeJob | ReminderJob;

export const isBadgeJob = (job: QueueJob): job is BadgeJob => (job as BadgeJob).kind === "badge";
export const isReminderJob = (job: QueueJob): job is ReminderJob => (job as ReminderJob).kind === "reminder";

export interface ReminderHook {
  remind(job: ReminderJob): Promise<void>;
}

/** Reminder pushes share the push queue (and are off with it). */
export function queueReminders(env: Pick<Env, "PUSH_QUEUE">): ReminderHook {
  return {
    remind: async (job) => {
      if (env.PUSH_QUEUE) await env.PUSH_QUEUE.send(job);
    },
  };
}

/** An envelope longer than this (JSON characters = bytes, it is ASCII) is not attached to a push. */
export const MAX_PREVIEW_ENVELOPE = 3000;

export interface PushHook {
  notify(job: PushJob): Promise<void>;
}

export interface BadgeHook {
  update(job: BadgeJob): Promise<void>;
}

/** Badge updates go only to phones: their app icon is what shows the number. */
export const BADGE_PLATFORMS = ["ios", "android"] as const;

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

/** Badge updates share the push queue (and are off with it). */
export function queueBadges(env: Pick<Env, "PUSH_QUEUE">): BadgeHook {
  return {
    update: async (job) => {
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
 * [at]: when the socket connected (Unix ms). Sockets from older versions may also carry `rv` (the
 * reviewer "side" that families replaced); it is ignored.
 */
type Att = { userId: string; deviceId: string; at: number };
type Incoming = Record<string, unknown>;

export const MAX_ENVELOPE_BYTES = 64 * 1024;
const B64URL = /^[A-Za-z0-9_-]+$/;

export type Envelope = { v: 1; epoch: number; nonce: string; ct: string; sig: string };

/** Why a message can't be stored (sent as the `error` of a `send`). */
type SendError = "not_member" | "no_shared_family" | "stale_epoch";

/** One message to store and fan out ([FamilyHub.deliver]). */
interface Delivery {
  userId: string;
  deviceId: string;
  chatId: string;
  id: string;
  envelope: Envelope;
  silent: boolean;
  mentions?: string[];
  /** It is the scheduled message of the same id: that row goes in the same batch. */
  scheduled: boolean;
  /** The sending socket, which gets an ack instead of the `msg`. */
  exclude?: WebSocket;
}

/** A scheduled message as `PUT /me/scheduled/:id` takes it (checked by the route). */
export interface ScheduleIn {
  id: string;
  chatId: string;
  envelope: Envelope;
  deliverAt: number;
  silent: boolean;
  mentions: string[] | null;
}

const SCHEDULED_COLS =
  "id, chat_id, sender_user_id, sender_device_id, envelope, silent, mentions, deliver_at, state, attempts, created_at, updated_at";

export type ScheduledRow = {
  id: string;
  chat_id: string;
  sender_user_id: string;
  sender_device_id: string;
  envelope: string;
  silent: number;
  mentions: string | null;
  deliver_at: number;
  state: "pending" | "needs_resend" | "failed";
  attempts: number;
  created_at: number;
  updated_at: number;
};

export type ScheduledOut = ReturnType<typeof scheduledOut>;

export function scheduledOut(r: ScheduledRow) {
  return {
    id: r.id,
    chatId: r.chat_id,
    senderDeviceId: r.sender_device_id,
    envelope: JSON.parse(r.envelope) as Envelope,
    silent: r.silent === 1,
    mentions: r.mentions ? (JSON.parse(r.mentions) as string[]) : [],
    deliverAt: r.deliver_at,
    state: r.state,
    createdAt: r.created_at,
    updatedAt: r.updated_at,
  };
}

type ReminderRow = { user_id: string; chat_id: string; message_id: string; remind_at: number; attempts: number };

/** Due items handled per kind per alarm run; a full batch runs the alarm again at once. */
export const DUE_BATCH = 50;

export function hubStub(env: Env) {
  return env.HUB.get(env.HUB.idFromName("family"));
}

export class FamilyHub extends DurableObject<Env> {
  /** Replaced in tests. */
  push: PushHook;

  /** Replaced in tests. */
  badges: BadgeHook;

  /** Replaced in tests. */
  reminderPush: ReminderHook;

  /** The clock (stale sockets, message times, due items); replaced in tests. */
  now: () => number = Date.now;

  /**
   * Sends run one at a time, so seqs are handed out and fanned out in order. Scheduled-message
   * operations and alarm runs join the same queue ([serial]).
   */
  private sends: Promise<void> = Promise.resolve();

  /** Media evictions run one at a time, so two uploads past the cap never both evict. */
  private evictions: Promise<unknown> = Promise.resolve();

  /**
   * Who shares a family with each user (themselves included), loaded from D1 on connect or when
   * first needed. In memory only: lost on hibernation and reloaded lazily; [sharesChanged] clears it.
   */
  private peers = new Map<string, Set<string>>();

  /** Bumped by [sharesChanged], so a load that was in flight then isn't cached. */
  private peersGen = 0;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.push = queuePush(env);
    this.badges = queueBadges(env);
    this.reminderPush = queueReminders(env);
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair('{"type":"ping"}', '{"type":"pong"}'));
  }

  /** Called by the Worker's /api/ws route after it checked the ticket. */
  async fetch(req: Request): Promise<Response> {
    const userId = req.headers.get("x-famchat-user");
    const deviceId = req.headers.get("x-famchat-device");
    if (!userId || !deviceId || req.headers.get("upgrade")?.toLowerCase() !== "websocket") {
      return new Response("bad request", { status: 400 });
    }
    await this.prune();
    // A connect always reloads the user's peers: they may have joined a family since.
    this.peers.delete(userId);
    const peers = await this.peersOf(userId);
    // Before accept, so the new socket isn't counted yet: add the user as it will be once accepted.
    const online = new Set(await this.onlineUserIds(undefined, userId));
    if (peers.has(userId)) online.add(userId);
    // No await from here on: nothing reaches the socket before hello, and presence can't interleave.
    const [client, server] = Object.values(new WebSocketPair());
    const wasOnline = this.sockets(userId).length > 0;
    this.ctx.acceptWebSocket(server, [`u:${userId}`, `d:${deviceId}`]);
    server.serializeAttachment({ userId, deviceId, at: this.now() } satisfies Att);
    server.send(JSON.stringify({ type: "hello", online: [...online] }));
    if (!wasOnline) this.sendPresence(userId, true, peers, server);
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
      case "send":
        return this.serial(() => this.handleSend(ws, att, m))
          .catch(() => send(ws, { type: "error", id: typeof m.id === "string" ? m.id : undefined, error: "internal" }));
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
    await this.goneOffline(ws);
  }

  async webSocketError(ws: WebSocket): Promise<void> {
    await this.goneOffline(ws);
  }

  // --- RPC from the Worker ---

  /** Family membership changed (a join, a deletion): drops every cached peer set. */
  async sharesChanged(): Promise<void> {
    this.peers.clear();
    this.peersGen++;
  }

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
      await this.goneOffline(ws);
    }
  }

  /** Expires the oldest media while the family is over the cap; returns how many objects. */
  async evictMedia(): Promise<number> {
    const run = this.evictions.then(() => evictOldest(this.env, (userIds, event) => this.notify(userIds, event)));
    this.evictions = run.catch(() => {});
    return (await run).length;
  }

  /** Who is online; with [viewer], only people who share a family with them (themselves included). */
  async onlineUserIds(exclude?: WebSocket, viewer?: string): Promise<string[]> {
    const visible = viewer === undefined ? null : await this.peersOf(viewer);
    const ids = new Set<string>();
    for (const ws of this.ctx.getWebSockets()) {
      if (ws === exclude || ws.readyState !== WebSocket.READY_STATE_OPEN) continue;
      const att = ws.deserializeAttachment() as Att | null;
      if (att && (!visible || visible.has(att.userId))) ids.add(att.userId);
    }
    return [...ids];
  }

  // --- internals ---

  /** Closes half-open sockets (see [STALE_SOCKET_MS]), except [keep], which just spoke. */
  private async prune(keep?: WebSocket): Promise<void> {
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
      await this.goneOffline(ws);
    }
  }

  /** Live users sharing a family with [userId], themselves included (cached, see [peers]). */
  private async peersOf(userId: string): Promise<Set<string>> {
    let set = this.peers.get(userId);
    if (!set) {
      const gen = this.peersGen;
      set = new Set(await familyPeers(this.env.DB, userId));
      if (gen === this.peersGen) this.peers.set(userId, set);
    }
    return set;
  }

  private sockets(userId: string, exclude?: WebSocket): WebSocket[] {
    return this.ctx.getWebSockets(`u:${userId}`).filter(
      (ws) => ws !== exclude && ws.readyState === WebSocket.READY_STATE_OPEN,
    );
  }

  /**
   * Sends [userId]'s presence to the sockets of [peers] (everyone who shares a family with them).
   * Synchronous, so callers decide and send with no await in between.
   */
  private sendPresence(userId: string, online: boolean, peers: Set<string>, exclude?: WebSocket, lastSeenAt?: number): void {
    const text = JSON.stringify({ type: "presence", userId, online, ...(lastSeenAt === undefined ? {} : { lastSeenAt }) });
    for (const ws of this.ctx.getWebSockets()) {
      if (ws === exclude) continue;
      const att = ws.deserializeAttachment() as Att | null;
      if (att && peers.has(att.userId)) trySend(ws, text);
    }
  }

  private async goneOffline(ws: WebSocket): Promise<void> {
    const att = ws.deserializeAttachment() as Att | null;
    if (!att) return;
    // Only once per socket: a revoked socket is seen here and again in webSocketClose.
    ws.serializeAttachment(null);
    // Peers first: a reconnect during this (maybe D1) load must be seen by the check below.
    const peers = await this.peersOf(att.userId);
    if (this.sockets(att.userId, ws).length !== 0) return;
    const at = this.now();
    this.sendPresence(att.userId, false, peers, ws, at);
    // "Last seen": after the frame, so a reconnect during the write can't be overtaken by it.
    await this.env.DB.prepare("UPDATE users SET last_seen_at = ? WHERE id = ?").bind(at, att.userId).run()
      .catch((e) => console.error("last seen not saved", e));
  }

  private async memberIds(chatId: string): Promise<string[]> {
    const { results } = await this.env.DB.prepare("SELECT user_id FROM chat_members WHERE chat_id = ?")
      .bind(chatId).all<{ user_id: string }>();
    return results.map((r) => r.user_id);
  }

  /** Runs [fn] after every earlier send, scheduled operation and alarm run (they share one queue). */
  private serial<T>(fn: () => Promise<T>): Promise<T> {
    const run = this.sends.then(fn);
    this.sends = run.then(() => {}, (e) => console.error("serial task failed", e));
    return run;
  }

  /**
   * Membership, family and epoch checks for [userId] storing [epoch] in [chatId]: null when they may,
   * else the error code.
   */
  private async sendGate(userId: string, chatId: string, epoch: number): Promise<SendError | null> {
    const chat = await this.env.DB.prepare(
      `SELECT c.current_epoch,
         EXISTS (SELECT 1 FROM chat_epochs e WHERE e.chat_id = c.id AND e.epoch = c.current_epoch) AS ready,
         (c.kind = 'group'
          OR NOT EXISTS (SELECT 1 FROM chat_members o WHERE o.chat_id = c.id AND o.user_id <> m.user_id)
          OR EXISTS (
            SELECT 1 FROM chat_members o
            JOIN users ou ON ou.id = o.user_id AND ou.deleted_at IS NULL
            JOIN family_members fo ON fo.user_id = o.user_id
            JOIN family_members fm ON fm.family_id = fo.family_id AND fm.user_id = m.user_id
            WHERE o.chat_id = c.id AND o.user_id <> m.user_id)) AS may_send
       FROM chats c JOIN chat_members m ON m.chat_id = c.id AND m.user_id = ? WHERE c.id = ?`,
    ).bind(userId, chatId).first<{ current_epoch: number; ready: number; may_send: number }>();
    if (!chat) return "not_member";
    if (chat.may_send !== 1) return "no_shared_family";
    if (epoch !== chat.current_epoch || chat.ready !== 1) return "stale_epoch";
    return null;
  }

  /**
   * Stores and fans out one message: the one path for a `send` frame, a scheduled message coming due
   * and "send now". Checks membership, family and epoch, takes the next seq, stamps the chat's
   * disappearing timer, sends `msg` to every member socket but [d.exclude], and pushes offline
   * members. With [d.scheduled] the scheduled row of the same id is deleted in the same batch. The
   * caller has checked that the id is unused and sends the ack.
   */
  private async deliver(d: Delivery): Promise<{ seq: number; createdAt: number } | { error: SendError }> {
    const gate = await this.sendGate(d.userId, d.chatId, d.envelope.epoch);
    if (gate) return { error: gate };
    const db = this.env.DB;
    const now = this.now();
    const envJson = JSON.stringify(d.envelope);
    // Silent sends (reactions, edits, deletes) reach sockets marked as such, push no one and don't
    // count as chat activity.
    const silent = d.silent;
    const [, inserted] = await db.batch([
      db.prepare(
        "UPDATE chats SET last_seq = last_seq + 1, last_message_at = CASE WHEN ? THEN last_message_at ELSE ? END WHERE id = ?",
      ).bind(silent ? 1 : 0, now, d.chatId),
      // The chat's timer is stamped as it is now. The server deletes the message at the backstop,
      // or sooner once every other member read it (handleRead); with no other member, at once + timer.
      db.prepare(
        `INSERT INTO messages (chat_id, seq, id, sender_user_id, sender_device_id, envelope, created_at, silent,
           disappear_secs, delete_at, scheduled)
         SELECT id, last_seq, ?1, ?2, ?3, ?4, ?5, ?6, disappear_secs,
           CASE WHEN disappear_secs IS NULL THEN NULL
             WHEN EXISTS (SELECT 1 FROM chat_members o WHERE o.chat_id = chats.id AND o.user_id <> ?2)
               THEN ?5 + disappear_secs * 1000 + ?7
             ELSE ?5 + disappear_secs * 1000 END,
           ?8
         FROM chats WHERE id = ?9 RETURNING seq, disappear_secs, delete_at`,
      ).bind(d.id, d.userId, d.deviceId, envJson, now, silent ? 1 : 0, BACKSTOP_MS, d.scheduled ? 1 : 0, d.chatId),
      ...(d.scheduled ? [db.prepare("DELETE FROM scheduled_messages WHERE id = ?").bind(d.id)] : []),
    ]);
    const row = inserted.results[0] as { seq: number; disappear_secs: number | null; delete_at: number | null };
    const seq = row.seq;
    if (row.delete_at !== null) await this.armAt(row.delete_at);

    const memberList = await this.memberIds(d.chatId);
    // Only members other than the sender can be mentioned; silent changes mention no one.
    const mentioned = silent ? [] : [...new Set(d.mentions ?? [])]
      .filter((u) => u !== d.userId && memberList.includes(u));
    const msg = JSON.stringify({
      type: "msg",
      ...(silent ? { silent: true } : {}),
      ...(mentioned.length ? { mentions: mentioned } : {}),
      message: messageOut({
        chat_id: d.chatId, seq, id: d.id, sender_user_id: d.userId, sender_device_id: d.deviceId,
        envelope: envJson, created_at: now, disappear_secs: row.disappear_secs,
      }),
    });
    const others: string[] = [];
    for (const u of memberList) {
      for (const s of this.sockets(u, d.exclude)) trySend(s, msg);
      if (u !== d.userId) others.push(u);
    }
    if (silent) return { seq, createdAt: now };
    // Mentioned members get their own job (other text, and it reaches them through a mute).
    const job: Omit<PushJob, "userIds"> = {
      chatId: d.chatId,
      senderUserId: d.userId,
      messageId: d.id,
      ...(envJson.length <= MAX_PREVIEW_ENVELOPE
        ? { preview: { senderDeviceId: d.deviceId, epoch: d.envelope.epoch, envelope: envJson } }
        : {}),
    };
    // Not awaited: the next send shouldn't wait for the push lookup and the queue.
    this.pushOffline(job, others.filter((u) => !mentioned.includes(u))).catch((e) => console.error("push hook failed", e));
    if (mentioned.length > 0) {
      this.pushOffline({ ...job, mention: true }, mentioned, { throughMute: true }).catch((e) =>
        console.error("push hook failed", e),
      );
    }
    return { seq, createdAt: now };
  }

  private async handleSend(ws: WebSocket, att: Att, m: Incoming): Promise<void> {
    const id = m.id;
    const chatId = m.chatId;
    const env = m.envelope;
    await this.prune(ws);
    const mentions = parseMentions(m.mentions);
    if (!isUlid(id) || typeof chatId !== "string" || !validEnvelope(env) || mentions === false) {
      return send(ws, { type: "error", id: typeof id === "string" ? id : undefined, error: "invalid_request" });
    }
    const db = this.env.DB;
    const prior = await db.prepare(
      "SELECT chat_id, seq, sender_user_id, sender_device_id, created_at, scheduled FROM messages WHERE id = ?",
    ).bind(id).first<{ chat_id: string; seq: number; sender_user_id: string; sender_device_id: string; created_at: number; scheduled: number }>();
    if (prior) {
      // A scheduled message may be resent by any device of its sender (one of them delivered it).
      const mine = prior.sender_device_id === att.deviceId || (prior.scheduled === 1 && prior.sender_user_id === att.userId);
      if (prior.chat_id === chatId && mine) {
        return send(ws, { type: "ack", id, seq: prior.seq, createdAt: prior.created_at });
      }
      return send(ws, { type: "error", id, error: "conflict" });
    }
    // A send with a scheduled message's id delivers it now with this envelope (a re-encrypted
    // needs_resend, or "send now" with fresh content), from any device of its sender.
    const sched = await db.prepare("SELECT chat_id, sender_user_id FROM scheduled_messages WHERE id = ?")
      .bind(id).first<{ chat_id: string; sender_user_id: string }>();
    if (sched && (sched.chat_id !== chatId || sched.sender_user_id !== att.userId)) {
      return send(ws, { type: "error", id, error: "conflict" });
    }
    const r = await this.deliver({
      userId: att.userId, deviceId: att.deviceId, chatId, id, envelope: env,
      silent: m.silent === true, mentions: mentions ?? undefined, scheduled: !!sched, exclude: ws,
    });
    if ("error" in r) return send(ws, { type: "error", id, error: r.error });
    send(ws, { type: "ack", id, seq: r.seq, createdAt: r.createdAt });
    if (sched) {
      this.ackOwn(att.userId, id, r, ws);
      await this.notify([att.userId], { type: "scheduled" });
      await this.rearm();
    }
  }

  /** Sends `ack` for [id] to [userId]'s sockets but [exclude] (a scheduled message got delivered). */
  private ackOwn(userId: string, id: string, r: { seq: number; createdAt: number }, exclude?: WebSocket): void {
    const text = JSON.stringify({ type: "ack", id, seq: r.seq, createdAt: r.createdAt });
    for (const s of this.sockets(userId, exclude)) trySend(s, text);
  }

  // --- scheduled messages (docs/protocol.md "Scheduled messages") ---

  /**
   * Creates or replaces [userId]'s scheduled message [s.id], made by [deviceId]. The same content
   * again changes nothing (a retry). The id must be unused, or this user's scheduled message in the
   * same chat; the chat must take a send from them now (current epoch).
   */
  async putScheduled(userId: string, deviceId: string, s: ScheduleIn): Promise<
    { created: boolean; scheduled: ScheduledOut } | { error: "invalid_request" | "not_found" | "conflict" | "stale_epoch" | "no_shared_family" }
  > {
    return this.serial(async () => {
      const now = this.now();
      if (!validAhead(s.deliverAt, now)) return { error: "invalid_request" as const };
      const db = this.env.DB;
      if (await db.prepare("SELECT 1 AS x FROM messages WHERE id = ?").bind(s.id).first()) return { error: "conflict" as const };
      const prior = await db.prepare(`SELECT ${SCHEDULED_COLS} FROM scheduled_messages WHERE id = ?`).bind(s.id).first<ScheduledRow>();
      if (prior && (prior.sender_user_id !== userId || prior.chat_id !== s.chatId)) return { error: "conflict" as const };
      const gate = await this.sendGate(userId, s.chatId, s.envelope.epoch);
      if (gate === "not_member") return { error: "not_found" as const };
      if (gate) return { error: gate };
      const envJson = JSON.stringify(s.envelope);
      const mentionsJson = s.mentions ? JSON.stringify(s.mentions) : null;
      if (
        prior && prior.state === "pending" && prior.envelope === envJson && prior.deliver_at === s.deliverAt &&
        prior.silent === (s.silent ? 1 : 0) && prior.mentions === mentionsJson && prior.sender_device_id === deviceId
      ) {
        return { created: false, scheduled: scheduledOut(prior) };
      }
      const row = await db.prepare(
        `INSERT INTO scheduled_messages (id, chat_id, sender_user_id, sender_device_id, envelope, silent, mentions,
           deliver_at, state, next_at, attempts, created_at, updated_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, 'pending', ?8, 0, ?9, ?9)
         ON CONFLICT(id) DO UPDATE SET sender_device_id = ?4, envelope = ?5, silent = ?6, mentions = ?7,
           deliver_at = ?8, state = 'pending', next_at = ?8, attempts = 0, updated_at = ?9
         RETURNING ${SCHEDULED_COLS}`,
      ).bind(s.id, s.chatId, userId, deviceId, envJson, s.silent ? 1 : 0, mentionsJson, s.deliverAt, now).first<ScheduledRow>();
      await this.rearm();
      await this.notify([userId], { type: "scheduled" });
      return { created: !prior, scheduled: scheduledOut(row!) };
    });
  }

  /** Cancels [userId]'s scheduled message [id] and deletes the media uploaded for it. */
  async cancelScheduled(userId: string, id: string): Promise<{ ok: true } | { error: "not_found" }> {
    return this.serial(async () => {
      const row = await this.env.DB.prepare(
        "DELETE FROM scheduled_messages WHERE id = ? AND sender_user_id = ? RETURNING chat_id",
      ).bind(id, userId).first<{ chat_id: string }>();
      if (!row) return { error: "not_found" as const };
      await this.dropScheduledMedia(row.chat_id, id, userId);
      await this.rearm();
      await this.notify([userId], { type: "scheduled" });
      return { ok: true as const };
    });
  }

  /** Delivers [userId]'s scheduled message [id] now, with its stored envelope. */
  async sendScheduledNow(userId: string, id: string): Promise<
    { seq: number; createdAt: number } | { error: "not_found" | "stale_epoch" | "no_shared_family" }
  > {
    return this.serial(async () => {
      const row = await this.env.DB.prepare(`SELECT ${SCHEDULED_COLS} FROM scheduled_messages WHERE id = ? AND sender_user_id = ?`)
        .bind(id, userId).first<ScheduledRow>();
      if (!row) return { error: "not_found" as const };
      const r = await this.deliverScheduled(row);
      await this.rearm();
      if (r === "delivered") {
        const m = await this.env.DB.prepare("SELECT seq, created_at FROM messages WHERE id = ?").bind(id)
          .first<{ seq: number; created_at: number }>();
        return { seq: m!.seq, createdAt: m!.created_at };
      }
      return { error: r === "not_member" ? ("not_found" as const) : r };
    });
  }

  /** Due times may have moved (a reminder set or cleared, someone left a chat): re-arms the alarm. */
  async timersChanged(): Promise<void> {
    await this.serial(() => this.rearm());
  }

  /**
   * Delivers a scheduled row with its stored envelope, then tells the sender's sockets. A sender no
   * longer in the chat drops it; a moved-on epoch makes it needs_resend; a direct chat with no shared
   * family any more marks it failed.
   */
  private async deliverScheduled(row: ScheduledRow): Promise<"delivered" | SendError> {
    const db = this.env.DB;
    const r = await this.deliver({
      userId: row.sender_user_id,
      deviceId: row.sender_device_id,
      chatId: row.chat_id,
      id: row.id,
      envelope: JSON.parse(row.envelope) as Envelope,
      silent: row.silent === 1,
      mentions: row.mentions ? (JSON.parse(row.mentions) as string[]) : undefined,
      scheduled: true,
    });
    if ("error" in r) {
      if (r.error === "not_member") {
        await db.prepare("DELETE FROM scheduled_messages WHERE id = ?").bind(row.id).run();
        await this.dropScheduledMedia(row.chat_id, row.id, row.sender_user_id);
      } else {
        const state = r.error === "stale_epoch" ? "needs_resend" : "failed";
        await db.prepare("UPDATE scheduled_messages SET state = ?, updated_at = ? WHERE id = ?").bind(state, this.now(), row.id).run();
        if (state === "needs_resend") {
          await this.notify([row.sender_user_id], { type: "needs_resend", chatId: row.chat_id, id: row.id });
        }
      }
      await this.notify([row.sender_user_id], { type: "scheduled" });
      return r.error;
    }
    this.ackOwn(row.sender_user_id, row.id, r);
    await this.notify([row.sender_user_id], { type: "scheduled" });
    return "delivered";
  }

  /** Deletes the media [userId] uploaded for scheduled message [id] that never went out. */
  private async dropScheduledMedia(chatId: string, id: string, userId: string): Promise<void> {
    const { results } = await this.env.DB.prepare(
      "DELETE FROM media WHERE chat_id = ? AND message_id = ? AND uploader_id = ? RETURNING key",
    ).bind(chatId, id, userId).all<{ key: string }>();
    if (results.length) await this.env.MEDIA.delete(results.map((r) => r.key)).catch((e) => console.error("R2 delete failed", e));
  }

  // --- the alarm: scheduled sends, reminders and disappearing messages coming due ---

  /** Runs everything due (in small batches; see [DUE_BATCH]) and re-arms for the next due item. */
  async alarm(): Promise<void> {
    await this.serial(() => this.runDue());
  }

  private async runDue(): Promise<void> {
    const now = this.now();
    let more = false;
    for (const phase of [() => this.dueScheduled(now), () => this.dueReminders(now), () => this.dueDeletions(now)]) {
      try {
        more = (await phase()) || more;
      } catch (e) {
        // Each phase on its own: one failing (D1 hiccup) doesn't hold the others back.
        console.error("alarm phase failed", e);
      }
    }
    await this.env.DB.prepare("DELETE FROM message_tombstones WHERE deleted_at < ?").bind(now - TOMBSTONE_KEEP_MS).run()
      .catch((e) => console.error("tombstone prune failed", e));
    // A full batch means more may be due: run again at once rather than waiting for the next time.
    if (more) await this.ctx.storage.setAlarm(now);
    else await this.rearm();
  }

  /** Delivers due scheduled messages; true when the batch was full. */
  private async dueScheduled(now: number): Promise<boolean> {
    const { results } = await this.env.DB.prepare(
      `SELECT ${SCHEDULED_COLS} FROM scheduled_messages WHERE state = 'pending' AND next_at <= ? ORDER BY next_at, id LIMIT ?`,
    ).bind(now, DUE_BATCH).all<ScheduledRow>();
    for (const row of results) {
      try {
        await this.deliverScheduled(row);
      } catch (e) {
        console.error("scheduled delivery failed", e);
        const attempts = row.attempts + 1;
        const failed = attempts >= MAX_ATTEMPTS;
        await this.env.DB.prepare(
          "UPDATE scheduled_messages SET attempts = ?, next_at = ?, state = ?, updated_at = ? WHERE id = ? AND state = 'pending'",
        ).bind(attempts, now + retryDelay(attempts), failed ? "failed" : "pending", now, row.id).run()
          .catch((e2) => console.error("scheduled retry not recorded", e2));
        if (failed) await this.notify([row.sender_user_id], { type: "scheduled" });
      }
    }
    return results.length === DUE_BATCH;
  }

  /** Fires due reminders; true when the batch was full. */
  private async dueReminders(now: number): Promise<boolean> {
    const db = this.env.DB;
    const { results } = await db.prepare(
      "SELECT user_id, chat_id, message_id, remind_at, attempts FROM reminders WHERE next_at <= ? ORDER BY next_at LIMIT ?",
    ).bind(now, DUE_BATCH).all<ReminderRow>();
    for (const r of results) {
      try {
        await this.fireReminder(r);
      } catch (e) {
        console.error("reminder failed", e);
        const attempts = r.attempts + 1;
        await (attempts >= MAX_ATTEMPTS
          ? db.prepare("DELETE FROM reminders WHERE user_id = ? AND message_id = ? AND remind_at = ?").bind(r.user_id, r.message_id, r.remind_at)
          : db.prepare("UPDATE reminders SET attempts = ?, next_at = ? WHERE user_id = ? AND message_id = ? AND remind_at = ?")
            .bind(attempts, now + retryDelay(attempts), r.user_id, r.message_id, r.remind_at)
        ).run().catch((e2) => console.error("reminder retry not recorded", e2));
      }
    }
    return results.length === DUE_BATCH;
  }

  /**
   * A reminder's time came: a `reminder` frame to every socket of its owner and a push to their
   * devices with a token and no open socket (with the envelope for previews when small enough), then
   * the row goes. A reminder for a message that is gone, or in a chat they left, is just dropped.
   */
  private async fireReminder(r: ReminderRow): Promise<void> {
    const db = this.env.DB;
    const msg = await db.prepare(
      `SELECT m.sender_user_id, m.sender_device_id, m.envelope FROM messages m
       JOIN chat_members cm ON cm.chat_id = m.chat_id AND cm.user_id = ?
       WHERE m.id = ? AND m.chat_id = ?`,
    ).bind(r.user_id, r.message_id, r.chat_id).first<{ sender_user_id: string; sender_device_id: string; envelope: string }>();
    if (msg) {
      await this.notify([r.user_id], { type: "reminder", chatId: r.chat_id, messageId: r.message_id, at: r.remind_at });
      const { results } = await db.prepare(
        "SELECT id FROM devices WHERE user_id = ? AND revoked_at IS NULL AND push_token IS NOT NULL ORDER BY id",
      ).bind(r.user_id).all<{ id: string }>();
      const targets = results.map((d) => d.id).filter((id) => !this.deviceOnline(id));
      if (targets.length) {
        const epoch = (JSON.parse(msg.envelope) as { epoch: number }).epoch;
        await this.reminderPush.remind({
          kind: "reminder",
          userId: r.user_id,
          chatId: r.chat_id,
          messageId: r.message_id,
          at: r.remind_at,
          senderUserId: msg.sender_user_id,
          deviceIds: targets,
          ...(msg.envelope.length <= MAX_PREVIEW_ENVELOPE
            ? { preview: { senderDeviceId: msg.sender_device_id, epoch, envelope: msg.envelope } }
            : {}),
        });
      }
    }
    // Only the reminder that fired: one set again meanwhile (another time) stays.
    await db.prepare("DELETE FROM reminders WHERE user_id = ? AND message_id = ? AND remind_at = ?")
      .bind(r.user_id, r.message_id, r.remind_at).run();
  }

  /** Deletes disappearing messages whose time came; true when the batch was full. */
  private async dueDeletions(now: number): Promise<boolean> {
    const db = this.env.DB;
    const { results } = await db.prepare(
      "SELECT chat_id, id FROM messages WHERE delete_at <= ? ORDER BY delete_at LIMIT ?",
    ).bind(now, DUE_BATCH).all<{ chat_id: string; id: string }>();
    const byChat = new Map<string, string[]>();
    for (const r of results) byChat.set(r.chat_id, [...(byChat.get(r.chat_id) ?? []), r.id]);
    for (const [chatId, ids] of byChat) {
      try {
        await this.deleteMessages(chatId, ids, now);
      } catch (e) {
        // Deletion must happen eventually: try these again in 10 minutes, the rest go on.
        console.error("message deletion failed", e);
        await db.prepare(`UPDATE messages SET delete_at = ? WHERE chat_id = ? AND id IN (${ids.map(() => "?").join(",")})`)
          .bind(now + 600_000, chatId, ...ids).run().catch((e2) => console.error("deletion retry not recorded", e2));
      }
    }
    return results.length === DUE_BATCH;
  }

  /**
   * Deletes messages [ids] of [chatId] (due at [now]) with their media blobs, stars and reminders,
   * leaves a tombstone for each (GET /me/gone), and sends `gone` to the members' sockets.
   */
  private async deleteMessages(chatId: string, ids: string[], now: number): Promise<void> {
    const db = this.env.DB;
    const q = ids.map(() => "?").join(",");
    const [media, , , , gone] = await db.batch([
      // Live rows lower media_usage through the delete trigger.
      db.prepare(`DELETE FROM media WHERE chat_id = ? AND message_id IN (${q}) RETURNING key`).bind(chatId, ...ids),
      db.prepare(`DELETE FROM starred_messages WHERE chat_id = ? AND message_id IN (${q})`).bind(chatId, ...ids),
      db.prepare(`DELETE FROM reminders WHERE chat_id = ? AND message_id IN (${q})`).bind(chatId, ...ids),
      db.prepare(
        `INSERT INTO message_tombstones (chat_id, seq, message_id, deleted_at)
         SELECT chat_id, seq, id, ? FROM messages WHERE chat_id = ? AND id IN (${q}) AND delete_at <= ? ORDER BY seq`,
      ).bind(now, chatId, ...ids, now),
      db.prepare(`DELETE FROM messages WHERE chat_id = ? AND id IN (${q}) AND delete_at <= ? RETURNING id`).bind(chatId, ...ids, now),
    ]);
    const keys = (media.results as { key: string }[]).map((r) => r.key);
    if (keys.length) {
      // The rows are gone either way; an orphaned object only costs storage.
      await this.env.MEDIA.delete(keys).catch((e) => console.error("R2 delete failed", e));
    }
    const deleted = (gone.results as { id: string }[]).map((r) => r.id);
    if (deleted.length) await this.notify(await this.memberIds(chatId), { type: "gone", chatId, ids: deleted });
  }

  /** Arms the alarm for [at] unless it already fires sooner. */
  private async armAt(at: number): Promise<void> {
    const cur = await this.ctx.storage.getAlarm();
    if (cur === null || at < cur) await this.ctx.storage.setAlarm(at);
  }

  /** Sets the alarm to the earliest due item of all three kinds, or clears it when nothing is due. */
  private async rearm(): Promise<void> {
    const next = await this.env.DB.prepare(
      `SELECT MIN(t) AS t FROM (
         SELECT MIN(next_at) AS t FROM scheduled_messages WHERE state = 'pending'
         UNION ALL SELECT MIN(next_at) FROM reminders
         UNION ALL SELECT MIN(delete_at) FROM messages WHERE delete_at IS NOT NULL)`,
    ).first<number | null>("t");
    if (next === null) await this.ctx.storage.deleteAlarm();
    else await this.ctx.storage.setAlarm(next);
  }

  private deviceOnline(deviceId: string): boolean {
    return this.ctx.getWebSockets(`d:${deviceId}`).some((s) => s.readyState === WebSocket.READY_STATE_OPEN);
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
    // Only to members who still share a family with the sender ("former" partners hear nothing).
    const peers = await this.peersOf(att.userId);
    const text = JSON.stringify({ type: "typing", chatId: m.chatId, userId: att.userId });
    for (const u of members) if (u !== att.userId && peers.has(u)) for (const s of this.sockets(u)) trySend(s, text);
  }

  private async handleRead(att: Att, m: Incoming): Promise<void> {
    if (typeof m.chatId !== "string" || !Number.isInteger(m.seq) || (m.seq as number) < 0) return;
    const before = await this.env.DB.prepare(
      "SELECT last_read_seq, joined_seq, muted_until FROM chat_members WHERE chat_id = ? AND user_id = ?",
    ).bind(m.chatId, att.userId).first<{ last_read_seq: number; joined_seq: number; muted_until: number | null }>();
    if (!before) return;
    const row = await this.env.DB.prepare(
      `UPDATE chat_members SET last_read_seq = MIN(?, (SELECT last_seq FROM chats WHERE id = ?))
       WHERE chat_id = ? AND user_id = ? AND last_read_seq < MIN(?, (SELECT last_seq FROM chats WHERE id = ?))
       RETURNING last_read_seq`,
    ).bind(m.seq, m.chatId, m.chatId, att.userId, m.seq, m.chatId).first<{ last_read_seq: number }>();
    if (!row) return;
    // Disappearing messages everyone has now read start their clock (one UPDATE per read).
    const { results: moved } = await this.env.DB.prepare(`${ALL_READ_SQL} RETURNING delete_at`)
      .bind(this.now(), m.chatId, before.last_read_seq, row.last_read_seq).all<{ delete_at: number }>();
    if (moved.length) await this.armAt(Math.min(...moved.map((r) => r.delete_at)));
    await this.notify(await this.memberIds(m.chatId), {
      type: "read", chatId: m.chatId, userId: att.userId, seq: row.last_read_seq,
    });
    // Not awaited, like message pushes.
    this.updateBadges(att, m.chatId, before, row.last_read_seq).catch((e) => console.error("badge hook failed", e));
  }

  /**
   * After [att]'s user read [chatId] up to [readSeq]: when that took messages off their badge
   * (others' non-silent messages after where they joined, in a chat that isn't muted), queues a
   * badge update for their other phones. The device that read updates its own badge.
   */
  private async updateBadges(
    att: Att,
    chatId: string,
    before: { last_read_seq: number; joined_seq: number; muted_until: number | null },
    readSeq: number,
  ): Promise<void> {
    if (before.muted_until !== null && before.muted_until > Date.now()) return;
    const db = this.env.DB;
    const cleared = await db.prepare(
      `SELECT EXISTS (SELECT 1 FROM messages WHERE chat_id = ? AND seq > ? AND seq <= ? AND silent = 0
       AND sender_user_id <> ?) AS n`,
    ).bind(chatId, Math.max(before.last_read_seq, before.joined_seq), readSeq, att.userId).first<number>("n");
    if (!cleared) return;
    const { results } = await db.prepare(
      `SELECT id FROM devices WHERE user_id = ? AND id <> ? AND revoked_at IS NULL AND push_token IS NOT NULL
       AND platform IN (${BADGE_PLATFORMS.map(() => "?").join(",")}) ORDER BY id`,
    ).bind(att.userId, att.deviceId, ...BADGE_PLATFORMS).all<{ id: string }>();
    if (results.length === 0) return;
    await this.badges.update({ kind: "badge", userId: att.userId, deviceIds: results.map((d) => d.id) });
  }
}

/** The `mentions` of a send: undefined/null when absent, false when malformed. */
export function parseMentions(v: unknown): string[] | null | false {
  if (v === undefined || v === null) return null;
  if (!Array.isArray(v) || v.length > MAX_MENTIONS || !v.every((u) => typeof u === "string")) return false;
  return v as string[];
}

export function validEnvelope(e: unknown): e is Envelope {
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
