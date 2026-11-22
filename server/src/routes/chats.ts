import { Hono } from "hono";
import type { AppEnv } from "../env";
import {
  chatOut, chatsOf, checkCoverage, isMember, isUlid, leaveGroupStmts, liveDeviceIds, parseWraps, requireMemberChat, wrapInserts,
} from "../lib/chatdb";
import { ApiError } from "../lib/errors";
import { groupFamilyFor, shares } from "../lib/family";
import { name, readJson } from "../lib/validate";
import { requireAuth } from "../middleware/auth";
import { type MessageRow, messageOut } from "../lib/messages";
import { notify, timersChanged } from "../notify";
import { DISAPPEAR_SECS, validAhead } from "../lib/timing";
import { newId } from "../lib/ids";
import { readAvatarJpeg } from "./me";

export const chats = new Hono<AppEnv>();
chats.use(requireAuth);

/** How many of [userIds] are live members of [familyId]. */
async function liveInFamily(db: D1Database, userIds: string[], familyId: number): Promise<number> {
  if (userIds.length === 0) return 0;
  return (await db.prepare(
    `SELECT COUNT(*) AS n FROM family_members m JOIN users u ON u.id = m.user_id AND u.deleted_at IS NULL
     WHERE m.family_id = ? AND m.user_id IN (${userIds.map(() => "?").join(",")})`,
  ).bind(familyId, ...userIds).first<number>("n")) ?? 0;
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
  let familyId: number | null = null;
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
    familyId = await groupFamilyFor(db, me, body.familyId);
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
  if (familyId === null) {
    // Direct: the other person must be live, and share a family with the caller.
    const live = await db.prepare("SELECT 1 AS ok FROM users WHERE id = ? AND deleted_at IS NULL").bind(others[0]).first();
    if (!live) throw new ApiError("invalid_request");
    if (!(await shares(db, me, others[0]))) throw new ApiError("no_shared_family");
  } else if ((await liveInFamily(db, others, familyId)) !== others.length) {
    throw new ApiError("invalid_request");
  }

  const members = [me, ...others];
  checkCoverage(wraps, { chatId: id, epoch: 1, wrapper: device, deviceIds: await liveDeviceIds(db, members) });
  if (wraps.some((w) => w.epoch !== 1)) throw new ApiError("wraps_mismatch");

  const now = Date.now();
  try {
    await db.batch([
      db.prepare(
        "INSERT INTO chats (id, kind, title, created_by, direct_key, family_id, current_epoch, last_seq, created_at) VALUES (?, ?, ?, ?, ?, ?, 1, 0, ?)",
      ).bind(id, body.kind, title, me, directKey, familyId, now),
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
  if (chat.familyId === null || (await liveInFamily(db, added, chat.familyId)) !== added.length) {
    throw new ApiError("invalid_request");
  }
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
  await db.batch(leaveGroupStmts(db, chat.id, target, Date.now()));
  await notify(c.env, [target], { type: "removed", chatId: chat.id });
  await notify(c.env, chat.members.map((m) => m.userId).filter((u) => u !== target), { type: "chat", chatId: chat.id });
  // Disappearing messages they hadn't read may be due sooner now.
  await timersChanged(c.env);
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

/**
 * The caller's own chat list state: any of `pinned`, `archived` and `unread` (booleans). Pinning or
 * archiving stamps the time; `unread: true` is "mark as unread", cleared by `unread: false` (the app
 * sends it when the chat is opened). Only the caller's own sockets get a `chat` event.
 */
chats.patch("/:id/me", async (c) => {
  const db = c.env.DB;
  const me = c.get("userId");
  const body = await readJson(c);
  const sets: string[] = [];
  const binds: unknown[] = [];
  const now = Date.now();
  for (const [field, col] of [["pinned", "pinned_at"], ["archived", "archived_at"]] as const) {
    if (body[field] === undefined) continue;
    if (typeof body[field] !== "boolean") throw new ApiError("invalid_request");
    sets.push(`${col} = ?`);
    binds.push(body[field] ? now : null);
  }
  if (body.unread !== undefined) {
    if (typeof body.unread !== "boolean") throw new ApiError("invalid_request");
    sets.push("marked_unread = ?");
    binds.push(body.unread ? 1 : 0);
  }
  if (sets.length === 0) throw new ApiError("invalid_request");
  const chatId = c.req.param("id");
  const res = await db.prepare(`UPDATE chat_members SET ${sets.join(", ")} WHERE chat_id = ? AND user_id = ?`)
    .bind(...binds, chatId, me).run();
  if (res.meta.changes !== 1) throw new ApiError("not_found");
  await notify(c.env, [me], { type: "chat", chatId });
  return c.body(null, 204);
});

/** Stars or unstars a message for the caller only (docs/protocol.md "Starred messages"). */
for (const method of ["put", "delete"] as const) {
  chats[method]("/:id/messages/:messageId/star", async (c) => {
    const db = c.env.DB;
    const me = c.get("userId");
    const chatId = c.req.param("id");
    const messageId = c.req.param("messageId");
    if (!isUlid(messageId)) throw new ApiError("not_found");
    const found = await db.prepare(
      `SELECT 1 AS ok FROM messages m JOIN chat_members cm ON cm.chat_id = m.chat_id AND cm.user_id = ?
       WHERE m.chat_id = ? AND m.id = ?`,
    ).bind(me, chatId, messageId).first<{ ok: number }>();
    if (!found) throw new ApiError("not_found");
    const res = method === "put"
      ? await db.prepare(
        "INSERT OR IGNORE INTO starred_messages (user_id, chat_id, message_id, starred_at) VALUES (?, ?, ?, ?)",
      ).bind(me, chatId, messageId, Date.now()).run()
      : await db.prepare("DELETE FROM starred_messages WHERE user_id = ? AND message_id = ?").bind(me, messageId).run();
    if (res.meta.changes > 0) await notify(c.env, [me], { type: "stars" });
    return c.body(null, 204);
  });
}

/**
 * Changes a chat (any member): `title` (groups only; titles aren't end-to-end encrypted) and/or
 * `disappearSecs` (null, 86400, 604800 or 7776000; any chat). Changing the timer records who did it,
 * when and at which seq, for the line clients show (docs/protocol.md "Disappearing messages").
 */
chats.patch("/:id", async (c) => {
  const db = c.env.DB;
  const me = c.get("userId");
  const chat = await requireMemberChat(db, c.req.param("id"), me);
  const body = await readJson(c);
  if (body.title === undefined && body.disappearSecs === undefined) throw new ApiError("invalid_request");
  const stmts: D1PreparedStatement[] = [];
  if (body.title !== undefined) {
    if (chat.kind !== "group") throw new ApiError("invalid_request");
    const raw = body.title;
    if (typeof raw === "string" && /[\u0000-\u001f\u007f]/.test(raw)) throw new ApiError("invalid_request");
    stmts.push(db.prepare("UPDATE chats SET title = ? WHERE id = ?").bind(name(raw, 60), chat.id));
  }
  if (body.disappearSecs !== undefined) {
    const secs = body.disappearSecs;
    if (secs !== null && !(typeof secs === "number" && DISAPPEAR_SECS.has(secs))) throw new ApiError("invalid_request");
    // Setting the value it already has records nothing (no line).
    stmts.push(db.prepare(
      `UPDATE chats SET disappear_secs = ?1, disappear_changed_by = ?2, disappear_changed_at = ?3,
         disappear_changed_seq = last_seq WHERE id = ?4 AND disappear_secs IS NOT ?1`,
    ).bind(secs, me, Date.now(), chat.id));
  }
  await db.batch(stmts);
  await notify(c.env, chat.members.map((m) => m.userId), { type: "chat", chatId: chat.id });
  return c.json({ chat: await chatOut(db, chat.id, me) });
});

/**
 * Sets (PUT `{at}`) or clears (DELETE) the caller's reminder for a message (docs/protocol.md
 * "Reminders"). 404 unless the caller is a member and the message is in that chat.
 */
chats.put("/:id/messages/:messageId/reminder", async (c) => {
  const db = c.env.DB;
  const me = c.get("userId");
  const chatId = c.req.param("id");
  const messageId = c.req.param("messageId");
  if (!isUlid(messageId)) throw new ApiError("not_found");
  const at = (await readJson(c)).at;
  const now = Date.now();
  if (!validAhead(at, now)) throw new ApiError("invalid_request");
  const res = await db.prepare(
    `INSERT INTO reminders (user_id, chat_id, message_id, remind_at, next_at, attempts, created_at)
     SELECT ?1, m.chat_id, m.id, ?2, ?2, 0, ?3 FROM messages m
     JOIN chat_members cm ON cm.chat_id = m.chat_id AND cm.user_id = ?1
     WHERE m.chat_id = ?4 AND m.id = ?5
     ON CONFLICT(user_id, message_id) DO UPDATE SET remind_at = ?2, next_at = ?2, attempts = 0
     RETURNING remind_at`,
  ).bind(me, at, now, chatId, messageId).first();
  if (!res) throw new ApiError("not_found");
  await timersChanged(c.env);
  await notify(c.env, [me], { type: "reminders" });
  return c.body(null, 204);
});

chats.delete("/:id/messages/:messageId/reminder", async (c) => {
  const db = c.env.DB;
  const me = c.get("userId");
  const chatId = c.req.param("id");
  if (!(await isMember(db, chatId, me))) throw new ApiError("not_found");
  const res = await db.prepare("DELETE FROM reminders WHERE user_id = ? AND chat_id = ? AND message_id = ?")
    .bind(me, chatId, c.req.param("messageId")).run();
  if (res.meta.changes > 0) {
    await timersChanged(c.env);
    await notify(c.env, [me], { type: "reminders" });
  }
  return c.body(null, 204);
});

export const chatAvatarObject = (chatId: string, key: string) => `chat-avatars/${chatId}/${key}`;

/** Sets [chatId]'s photo key to [key] and returns the one it replaced, in one transaction. */
async function swapChatAvatar(db: D1Database, chatId: string, key: string | null): Promise<string | null> {
  const [prev] = await db.batch([
    db.prepare("SELECT avatar_key FROM chats WHERE id = ?").bind(chatId),
    db.prepare("UPDATE chats SET avatar_key = ? WHERE id = ?").bind(key, chatId),
  ]);
  return (prev.results[0] as { avatar_key: string | null } | undefined)?.avatar_key ?? null;
}

/** Sets a group's photo (any member): the raw JPEG as the body. Answers the new avatarKey. */
chats.put("/:id/avatar", async (c) => {
  const db = c.env.DB;
  const chat = await requireMemberChat(db, c.req.param("id"), c.get("userId"));
  if (chat.kind !== "group") throw new ApiError("invalid_request");
  const body = await readAvatarJpeg(c);
  const key = newId();
  await c.env.MEDIA.put(chatAvatarObject(chat.id, key), body, { httpMetadata: { contentType: "image/jpeg" } });
  const old = await swapChatAvatar(db, chat.id, key);
  if (old) await c.env.MEDIA.delete(chatAvatarObject(chat.id, old)).catch(() => {});
  await notify(c.env, chat.members.map((m) => m.userId), { type: "chat", chatId: chat.id });
  return c.json({ avatarKey: key });
});

/** Removes a group's photo (any member). */
chats.delete("/:id/avatar", async (c) => {
  const db = c.env.DB;
  const chat = await requireMemberChat(db, c.req.param("id"), c.get("userId"));
  if (chat.kind !== "group") throw new ApiError("invalid_request");
  const old = await swapChatAvatar(db, chat.id, null);
  if (old) {
    await c.env.MEDIA.delete(chatAvatarObject(chat.id, old)).catch(() => {});
    await notify(c.env, chat.members.map((m) => m.userId), { type: "chat", chatId: chat.id });
  }
  return c.body(null, 204);
});

/** A group's photo, for members. With `?v=<avatarKey>` it's cacheable for good; 404 once replaced. */
chats.get("/:id/avatar", async (c) => {
  const chat = await requireMemberChat(c.env.DB, c.req.param("id"), c.get("userId"));
  const v = c.req.query("v");
  if (!chat.avatarKey || (v !== undefined && v !== chat.avatarKey)) throw new ApiError("not_found");
  const obj = await c.env.MEDIA.get(chatAvatarObject(chat.id, chat.avatarKey));
  if (!obj) throw new ApiError("not_found");
  return new Response(obj.body, {
    headers: {
      "content-type": "image/jpeg",
      "content-length": String(obj.size),
      "cache-control": v ? "private, max-age=31536000, immutable" : "private, no-cache",
    },
  });
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
  type Row = MessageRow;
  const cols = "chat_id, seq, id, sender_user_id, sender_device_id, envelope, created_at, disappear_secs";
  // A disappearing message past its time is left out even before the hub deleted it.
  const live = "(delete_at IS NULL OR delete_at > ?)";
  const now = Date.now();
  let rows: Row[];
  if (before !== undefined) {
    rows = (await db.prepare(`SELECT ${cols} FROM messages WHERE chat_id = ? AND seq < ? AND ${live} ORDER BY seq DESC LIMIT ?`)
      .bind(chat.id, before, now, limit).all<Row>()).results.reverse();
  } else {
    rows = (await db.prepare(`SELECT ${cols} FROM messages WHERE chat_id = ? AND seq > ? AND ${live} ORDER BY seq LIMIT ?`)
      .bind(chat.id, after ?? 0, now, limit).all<Row>()).results;
  }
  return c.json({ messages: rows.map(messageOut) });
});
