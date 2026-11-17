import { Hono } from "hono";
import type { AppEnv } from "../env";
import {
  chatOut, chatsOf, checkCoverage, isUlid, liveDeviceIds, parseWraps, requireMemberChat, wrapInserts,
} from "../lib/chatdb";
import { ApiError } from "../lib/errors";
import { name, readJson } from "../lib/validate";
import { requireAuth } from "../middleware/auth";
import { messageOut } from "../lib/messages";
import { notify } from "../notify";

export const chats = new Hono<AppEnv>();
chats.use(requireAuth);

/**
 * How many of [userIds] are live users on the caller's side: the family, or (for a reviewer) the
 * reviewer accounts. The two never share a chat (docs/protocol.md "Reviewer accounts").
 */
async function sameSide(db: D1Database, userIds: string[], reviewer: boolean): Promise<number> {
  if (userIds.length === 0) return 0;
  return (await db.prepare(
    `SELECT COUNT(*) AS n FROM users WHERE deleted_at IS NULL AND reviewer = ? AND id IN (${userIds.map(() => "?").join(",")})`,
  ).bind(reviewer ? 1 : 0, ...userIds).first<number>("n")) ?? 0;
}

chats.get("/", async (c) => c.json({ chats: await chatsOf(c.env.DB, c.get("userId")) }));

chats.get("/:id", async (c) => c.json({ chat: await requireMemberChat(c.env.DB, c.req.param("id"), c.get("userId")) }));

/**
 * Creates a chat with a client-made id (wrap signatures bind the chat id, so the wraps exist first).
 * Direct chats are deduped per pair; re-posting an id you created returns it unchanged.
 */
chats.post("/", async (c) => {
  const db = c.env.DB;
  const me = c.get("userId");
  const device = c.get("deviceId");
  const body = await readJson(c);
  const id = body.id;
  if (!isUlid(id)) throw new ApiError("invalid_request");
  let others: string[];
  let title: string | null = null;
  let directKey: string | null = null;
  if (body.kind === "direct") {
    if (typeof body.userId !== "string" || body.userId === me) throw new ApiError("invalid_request");
    others = [body.userId];
    directKey = [me, body.userId].sort().join(":");
  } else if (body.kind === "group") {
    title = name(body.title, 60);
    // No others is a chat with only yourself ("Note to self"), which lets a lone reviewer try the app.
    if (!Array.isArray(body.userIds) || body.userIds.length > 100) throw new ApiError("invalid_request");
    if (!body.userIds.every((u) => typeof u === "string" && u !== me)) throw new ApiError("invalid_request");
    others = [...new Set(body.userIds as string[])];
  } else {
    throw new ApiError("invalid_request");
  }
  const wraps = parseWraps(body.wraps);

  const existing = await db.prepare("SELECT created_by FROM chats WHERE id = ?").bind(id).first<{ created_by: string }>();
  if (existing) {
    if (existing.created_by !== me) throw new ApiError("invalid_request");
    return c.json({ chat: await chatOut(db, id, me), created: false }, 200);
  }
  if (directKey) {
    const dup = await db.prepare("SELECT id FROM chats WHERE direct_key = ?").bind(directKey).first<{ id: string }>();
    if (dup) return c.json({ chat: await chatOut(db, dup.id, me), created: false }, 200);
  }
  if ((await sameSide(db, others, c.get("reviewer"))) !== others.length) throw new ApiError("invalid_request");

  const members = [me, ...others];
  checkCoverage(wraps, { chatId: id, epoch: 1, wrapper: device, deviceIds: await liveDeviceIds(db, members) });
  if (wraps.some((w) => w.epoch !== 1)) throw new ApiError("wraps_mismatch");

  const now = Date.now();
  try {
    await db.batch([
      db.prepare(
        "INSERT INTO chats (id, kind, title, created_by, direct_key, current_epoch, last_seq, created_at) VALUES (?, ?, ?, ?, ?, 1, 0, ?)",
      ).bind(id, body.kind, title, me, directKey, now),
      ...members.map((u) =>
        db.prepare("INSERT INTO chat_members (chat_id, user_id, joined_seq, last_read_seq, joined_at) VALUES (?, ?, 0, 0, ?)")
          .bind(id, u, now),
      ),
      db.prepare("INSERT INTO chat_epochs (chat_id, epoch, created_by_device, created_at) VALUES (?, 1, ?, ?)").bind(id, device, now),
      ...wrapInserts(db, wraps, now),
    ]);
  } catch (e) {
    // Lost a race: the same direct pair or id was created meanwhile.
    const dup = directKey
      ? await db.prepare("SELECT id FROM chats WHERE direct_key = ?").bind(directKey).first<{ id: string }>()
      : null;
    if (dup) return c.json({ chat: await chatOut(db, dup.id, me), created: false }, 200);
    throw e;
  }
  await notify(c.env, members, { type: "chat", chatId: id });
  return c.json({ chat: await chatOut(db, id, me), created: true }, 201);
});

/** Adds people to a group. Wraps for the current epoch must cover every new device; older epochs may come too. */
chats.post("/:id/members", async (c) => {
  const db = c.env.DB;
  const me = c.get("userId");
  const device = c.get("deviceId");
  const chat = await requireMemberChat(db, c.req.param("id"), me);
  if (chat.kind !== "group") throw new ApiError("invalid_request");
  const body = await readJson(c);
  if (!Array.isArray(body.userIds) || body.userIds.length === 0 || body.userIds.length > 100) {
    throw new ApiError("invalid_request");
  }
  if (!body.userIds.every((u) => typeof u === "string")) throw new ApiError("invalid_request");
  const added = [...new Set(body.userIds as string[])];
  if (added.some((u) => chat.members.some((m) => m.userId === u))) throw new ApiError("invalid_request");
  if ((await sameSide(db, added, c.get("reviewer"))) !== added.length) throw new ApiError("invalid_request");
  if (!chat.epochReady) throw new ApiError("stale_epoch");

  const wraps = parseWraps(body.wraps);
  const newDevices = await liveDeviceIds(db, added);
  checkCoverage(wraps, { chatId: chat.id, epoch: chat.currentEpoch, wrapper: device, deviceIds: newDevices });
  const { results: epochs } = await db.prepare("SELECT epoch FROM chat_epochs WHERE chat_id = ?").bind(chat.id)
    .all<{ epoch: number }>();
  const known_epochs = new Set(epochs.map((e) => e.epoch));
  const nd = new Set(newDevices);
  if (wraps.some((w) => !known_epochs.has(w.epoch) || !nd.has(w.recipientDeviceId))) throw new ApiError("wraps_mismatch");

  const now = Date.now();
  await db.batch([
    ...added.map((u) =>
      db.prepare(
        `INSERT INTO chat_members (chat_id, user_id, joined_seq, last_read_seq, joined_at)
         SELECT id, ?, last_seq, 0, ? FROM chats WHERE id = ?`,
      ).bind(u, now, chat.id),
    ),
    ...wrapInserts(db, wraps, now),
  ]);
  const out = (await chatOut(db, chat.id, me))!;
  await notify(c.env, out.members.map((m) => m.userId), { type: "chat", chatId: chat.id });
  return c.json({ chat: out });
});

/** Leave (yourself) or remove (creator only). Either way the chat moves to a new, not yet created epoch. */
chats.delete("/:id/members/:userId", async (c) => {
  const db = c.env.DB;
  const me = c.get("userId");
  const target = c.req.param("userId");
  const chat = await requireMemberChat(db, c.req.param("id"), me);
  if (chat.kind !== "group") throw new ApiError("invalid_request");
  if (target !== me && chat.createdBy !== me) throw new ApiError("forbidden");
  if (!chat.members.some((m) => m.userId === target)) throw new ApiError("not_found");
  await db.batch([
    db.prepare("DELETE FROM chat_members WHERE chat_id = ? AND user_id = ?").bind(chat.id, target),
    db.prepare("UPDATE chats SET current_epoch = current_epoch + 1 WHERE id = ?").bind(chat.id),
  ]);
  await notify(c.env, [target], { type: "removed", chatId: chat.id });
  await notify(c.env, chat.members.map((m) => m.userId).filter((u) => u !== target), { type: "chat", chatId: chat.id });
  return c.body(null, 204);
});

/** Latest accepted mute time (year 9999): "until I turn it back on" is sent as a far-off time. */
const MAX_MUTE = 253_402_300_799_000;

/** Mutes (no pushes until [until], Unix ms) or unmutes (null) the chat for the caller. */
chats.put("/:id/mute", async (c) => {
  const db = c.env.DB;
  const me = c.get("userId");
  const body = await readJson(c);
  const until = body.until;
  if (until !== null && (!Number.isInteger(until) || (until as number) < 0 || (until as number) > MAX_MUTE)) {
    throw new ApiError("invalid_request");
  }
  const chatId = c.req.param("id");
  const res = await db.prepare("UPDATE chat_members SET muted_until = ? WHERE chat_id = ? AND user_id = ?")
    .bind(until, chatId, me).run();
  if (res.meta.changes !== 1) throw new ApiError("not_found");
  await notify(c.env, [me], { type: "chat", chatId });
  return c.body(null, 204);
});

/** Publishes the key of the chat's current epoch (after a leave or removal). First one wins. */
chats.post("/:id/epochs", async (c) => {
  const db = c.env.DB;
  const device = c.get("deviceId");
  const me = c.get("userId");
  const chat = await requireMemberChat(db, c.req.param("id"), me);
  const body = await readJson(c);
  if (!Number.isInteger(body.epoch)) throw new ApiError("invalid_request");
  const wraps = parseWraps(body.wraps);
  if (body.epoch !== chat.currentEpoch) throw new ApiError("stale_epoch");
  if (chat.epochReady) throw new ApiError("epoch_exists");
  checkCoverage(wraps, {
    chatId: chat.id,
    epoch: chat.currentEpoch,
    wrapper: device,
    deviceIds: await liveDeviceIds(db, chat.members.map((m) => m.userId)),
  });
  if (wraps.some((w) => w.epoch !== chat.currentEpoch)) throw new ApiError("wraps_mismatch");
  const now = Date.now();
  let created: D1Result[];
  try {
    created = await db.batch([
      db.prepare(
        `INSERT INTO chat_epochs (chat_id, epoch, created_by_device, created_at)
         SELECT id, current_epoch, ?, ? FROM chats WHERE id = ? AND current_epoch = ?`,
      ).bind(device, now, chat.id, chat.currentEpoch),
      // Only alongside the epoch row: if a removal moved the chat on meanwhile, neither is written.
      ...wraps.map((w) =>
        db.prepare(
          `INSERT OR IGNORE INTO chat_key_wraps (chat_id, epoch, device_id, wrapper_device_id, sealed, sig, created_at)
           SELECT ?, ?, ?, ?, ?, ?, ? WHERE EXISTS (
             SELECT 1 FROM chat_epochs WHERE chat_id = ? AND epoch = ? AND created_by_device = ? AND created_at = ?)`,
        ).bind(w.chatId, w.epoch, w.recipientDeviceId, w.wrapperDeviceId, w.sealed, w.sig, now, chat.id, chat.currentEpoch, device, now),
      ),
    ]);
  } catch (e) {
    if (String(e).includes("UNIQUE")) throw new ApiError("epoch_exists");
    throw e;
  }
  if (created[0].meta.changes !== 1) throw new ApiError("stale_epoch");
  await notify(c.env, chat.members.map((m) => m.userId), { type: "keys", chatId: chat.id, epoch: chat.currentEpoch });
  return c.json({ chat: await chatOut(db, chat.id, me) }, 201);
});

function seqParam(v: string | undefined): number | undefined {
  if (v === undefined) return undefined;
  if (!/^\d{1,15}$/.test(v)) throw new ApiError("invalid_request");
  return Number(v);
}

/** History: `after=N` (ascending from N+1) or `before=N` (the latest rows below N, ascending). */
chats.get("/:id/messages", async (c) => {
  const db = c.env.DB;
  const chat = await requireMemberChat(db, c.req.param("id"), c.get("userId"));
  const after = seqParam(c.req.query("after"));
  const before = seqParam(c.req.query("before"));
  if (after !== undefined && before !== undefined) throw new ApiError("invalid_request");
  const limitQ = seqParam(c.req.query("limit"));
  const limit = Math.min(Math.max(limitQ ?? 100, 1), 200);
  type Row = { chat_id: string; seq: number; id: string; sender_user_id: string; sender_device_id: string; envelope: string; created_at: number };
  const cols = "chat_id, seq, id, sender_user_id, sender_device_id, envelope, created_at";
  let rows: Row[];
  if (before !== undefined) {
    rows = (await db.prepare(`SELECT ${cols} FROM messages WHERE chat_id = ? AND seq < ? ORDER BY seq DESC LIMIT ?`)
      .bind(chat.id, before, limit).all<Row>()).results.reverse();
  } else {
    rows = (await db.prepare(`SELECT ${cols} FROM messages WHERE chat_id = ? AND seq > ? ORDER BY seq LIMIT ?`)
      .bind(chat.id, after ?? 0, limit).all<Row>()).results;
  }
  return c.json({ messages: rows.map(messageOut) });
});
