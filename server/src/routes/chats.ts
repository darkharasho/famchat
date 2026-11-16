import { Hono } from "hono";
import type { AppEnv } from "../env";
import {
  chatOut, chatsOf, checkCoverage, isUlid, liveDeviceIds, parseWraps, requireMemberChat, wrapInserts,
} from "../lib/chatdb";
import { ApiError } from "../lib/errors";
import { name, readJson } from "../lib/validate";
import { requireAuth } from "../middleware/auth";
import { notify } from "../notify";

export const chats = new Hono<AppEnv>();
chats.use(requireAuth);

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
    if (!Array.isArray(body.userIds) || body.userIds.length === 0 || body.userIds.length > 100) {
      throw new ApiError("invalid_request");
    }
    if (!body.userIds.every((u) => typeof u === "string" && u !== me)) throw new ApiError("invalid_request");
    others = [...new Set(body.userIds as string[])];
  } else {
    throw new ApiError("invalid_request");
  }
  const wraps = parseWraps(body.wraps);

  const existing = await db.prepare("SELECT created_by FROM chats WHERE id = ?").bind(id).first<{ created_by: string }>();
  if (existing) {
    if (existing.created_by !== me) throw new ApiError("invalid_request");
    return c.json({ chat: await chatOut(db, id), created: false }, 200);
  }
  if (directKey) {
    const dup = await db.prepare("SELECT id FROM chats WHERE direct_key = ?").bind(directKey).first<{ id: string }>();
    if (dup) return c.json({ chat: await chatOut(db, dup.id), created: false }, 200);
  }
  const known = await db.prepare(
    `SELECT COUNT(*) AS n FROM users WHERE id IN (${others.map(() => "?").join(",")})`,
  ).bind(...others).first<number>("n");
  if (known !== others.length) throw new ApiError("invalid_request");

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
    if (dup) return c.json({ chat: await chatOut(db, dup.id), created: false }, 200);
    throw e;
  }
  await notify(c.env, members, { type: "chat", chatId: id });
  return c.json({ chat: await chatOut(db, id), created: true }, 201);
});
