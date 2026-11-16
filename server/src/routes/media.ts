// Encrypted media through the Worker: R2 holds only ciphertext; access follows chat membership.
import { Hono } from "hono";
import type { AppEnv } from "../env";
import { hubStub } from "../hub";
import { isMember, isUlid } from "../lib/chatdb";
import { ApiError } from "../lib/errors";
import { KIND_LIMITS, MEDIA_CAP, mediaUsage } from "../lib/media";
import { requireAuth } from "../middleware/auth";

export const media = new Hono<AppEnv>();
media.use(requireAuth);

type MediaRow = {
  uploader_device_id: string;
  chat_id: string;
  bytes: number;
  expired_at: number | null;
};

/** POST /media?chatId&key&kind[&messageId] with the raw ciphertext as the body. */
media.post("/", async (c) => {
  const chatId = c.req.query("chatId");
  const key = c.req.query("key");
  const kind = c.req.query("kind") ?? "";
  const messageId = c.req.query("messageId");
  const limit = KIND_LIMITS.get(kind);
  if (!isUlid(chatId) || !isUlid(key) || limit === undefined || (messageId !== undefined && !isUlid(messageId))) {
    throw new ApiError("invalid_request");
  }
  const lengthHeader = c.req.header("content-length");
  if (!lengthHeader || !/^\d{1,12}$/.test(lengthHeader)) throw new ApiError("invalid_request");
  const length = Number(lengthHeader);
  if (length < 1) throw new ApiError("invalid_request");

  const db = c.env.DB;
  const userId = c.get("userId");
  const deviceId = c.get("deviceId");
  if (!(await isMember(db, chatId, userId))) throw new ApiError("not_found");
  if (length > limit) throw new ApiError("too_large");

  const body = c.req.raw.body;
  if (!body) throw new ApiError("invalid_request");

  // Reserve the key first, so the bytes count toward the quota before they reach R2.
  // (RETURNING, not meta.changes: that would also count the usage trigger's update.)
  const created = !!(await db.prepare(
    `INSERT INTO media (key, uploader_id, uploader_device_id, chat_id, message_id, kind, bytes, created_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(key) DO NOTHING RETURNING key`,
  ).bind(key, userId, deviceId, chatId, messageId ?? null, kind, length, Date.now()).first());
  if (!created) {
    // The same upload again (a retry after a lost response, or one still in flight): store the
    // body again and answer 200. Anything else claiming this key is a conflict.
    const prior = await db.prepare("SELECT uploader_device_id, chat_id, bytes, expired_at FROM media WHERE key = ?")
      .bind(key).first<MediaRow>();
    const same = prior && prior.uploader_device_id === deviceId && prior.chat_id === chatId &&
      prior.bytes === length && prior.expired_at === null;
    if (!same) throw new ApiError("conflict");
  }

  // FixedLengthStream makes R2 refuse a body that doesn't match Content-Length.
  const fixed = new FixedLengthStream(length);
  try {
    await Promise.all([
      body.pipeTo(fixed.writable),
      c.env.MEDIA.put(key, fixed.readable, { httpMetadata: { contentType: "application/octet-stream" } }),
    ]);
  } catch {
    if (created) {
      await c.env.MEDIA.delete(key).catch(() => {});
      await db.prepare("DELETE FROM media WHERE key = ?").bind(key).run();
    }
    throw new ApiError("invalid_request");
  }
  if (!created) return c.json({ key, bytes: length }, 200);

  if ((await mediaUsage(db)) > MEDIA_CAP) {
    try {
      await hubStub(c.env).evictMedia();
    } catch (e) {
      // The next upload past the cap tries again.
      console.error("media eviction failed", e);
    }
  }
  return c.json({ key, bytes: length }, 201);
});

media.get("/:key", async (c) => {
  const key = c.req.param("key");
  if (!isUlid(key)) throw new ApiError("not_found");
  const row = await c.env.DB.prepare("SELECT chat_id, expired_at FROM media WHERE key = ?")
    .bind(key).first<{ chat_id: string; expired_at: number | null }>();
  if (!row || !(await isMember(c.env.DB, row.chat_id, c.get("userId")))) throw new ApiError("not_found");
  if (row.expired_at !== null) throw new ApiError("media_expired");
  const obj = await c.env.MEDIA.get(key);
  if (!obj) throw new ApiError("media_expired");
  return new Response(obj.body, {
    headers: {
      "content-type": "application/octet-stream",
      "content-length": String(obj.size),
      "cache-control": "private, no-store",
    },
  });
});
