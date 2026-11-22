import { type Context, Hono } from "hono";
import type { AppEnv } from "../env";
import { deleteAccount } from "../lib/delete-account";
import { FAMILY_ONE, familyPeers } from "../lib/family";
import { newId } from "../lib/ids";
import { notify } from "../notify";
import { ApiError } from "../lib/errors";
import { name, readJson } from "../lib/validate";
import { requireAuth } from "../middleware/auth";

export const me = new Hono<AppEnv>();
me.use(requireAuth);

/** The signed-in user's profile. isAdmin comes from the database, not the access token. */
/** The caller's starred messages, newest first, in chats they're still in (docs/protocol.md "Starred messages"). */
me.get("/stars", async (c) => {
  const rows = await c.env.DB.prepare(
    `SELECT s.chat_id AS chatId, s.message_id AS messageId, s.starred_at AS starredAt
     FROM starred_messages s
     JOIN chat_members cm ON cm.chat_id = s.chat_id AND cm.user_id = s.user_id
     JOIN messages m ON m.id = s.message_id AND m.chat_id = s.chat_id
     WHERE s.user_id = ? ORDER BY s.starred_at DESC, s.message_id DESC LIMIT 5000`,
  ).bind(c.get("userId")).all<{ chatId: string; messageId: string; starredAt: number }>();
  return c.json({ stars: rows.results });
});

me.get("/", async (c) => {
  const row = await c.env.DB.prepare(`SELECT name, operator, recovery_pub IS NOT NULL AS has_recovery,
       EXISTS (SELECT 1 FROM family_members WHERE family_id = ? AND user_id = users.id AND role = 'admin') AS is_admin
     FROM users WHERE id = ?`)
    .bind(FAMILY_ONE, c.get("userId"))
    .first<{ name: string; is_admin: number; operator: number; has_recovery: number }>();
  if (!row) throw new ApiError("unauthorized");
  return c.json({
    userId: c.get("userId"),
    deviceId: c.get("deviceId"),
    name: row.name,
    // Admin of family #1 (the original family).
    isAdmin: row.is_admin === 1,
    operator: row.operator === 1,
    // An admin recovery key is registered (the printed code was saved).
    recoveryCodeSet: row.has_recovery === 1,
    // A reviewer account (docs/protocol.md "Reviewer accounts").
    reviewer: c.get("reviewer"),
    // KLIPY's terms have apps call it directly, so the app needs the key (null: GIFs are off).
    gifKey: c.env.KLIPY_APP_KEY || null,
  });
});

/** Renames the caller (`{name}`, 1–40 characters, the same limit as an invite's). */
me.put("/name", async (c) => {
  const raw = (await readJson(c)).name;
  // No line breaks or other control characters: names show on one line everywhere.
  if (typeof raw === "string" && /[\u0000-\u001f\u007f]/.test(raw)) throw new ApiError("invalid_request");
  const newName = name(raw, 40);
  const userId = c.get("userId");
  await c.env.DB.prepare("UPDATE users SET name = ? WHERE id = ? AND deleted_at IS NULL").bind(newName, userId).run();
  await notify(c.env, await familyPeers(c.env.DB, userId), { type: "profile", userId });
  return c.body(null, 204);
});

/** Largest profile photo (the app sends a 512 px JPEG, usually 30–80 KB). */
export const MAX_AVATAR_BYTES = 256 * 1024;

export const avatarObject = (userId: string, key: string) => `avatars/${userId}/${key}`;

/** Sets [userId]'s avatar key to [key] and returns the one it replaced, in one transaction (so two
 * uploads at once each see a different previous key, and none is left behind). */
async function swapAvatar(db: D1Database, userId: string, key: string | null): Promise<string | null> {
  const [prev] = await db.batch([
    db.prepare("SELECT avatar_key FROM users WHERE id = ?").bind(userId),
    db.prepare("UPDATE users SET avatar_key = ? WHERE id = ?").bind(key, userId),
  ]);
  return (prev.results[0] as { avatar_key: string | null } | undefined)?.avatar_key ?? null;
}

/** Sets the caller's profile photo: the raw JPEG as the body. Answers the new avatarKey. */
/** The request body as a photo for an avatar: a JPEG of at most [MAX_AVATAR_BYTES]. */
export async function readAvatarJpeg(c: Context<AppEnv>): Promise<Uint8Array> {
  if (c.req.header("content-type") !== "image/jpeg") throw new ApiError("invalid_request");
  // Refused before reading the body when it says it's too big.
  if (Number(c.req.header("content-length") ?? 0) > MAX_AVATAR_BYTES) throw new ApiError("too_large");
  const body = new Uint8Array(await c.req.arrayBuffer());
  if (body.length > MAX_AVATAR_BYTES) throw new ApiError("too_large");
  if (body.length < 3 || body[0] !== 0xff || body[1] !== 0xd8 || body[2] !== 0xff) throw new ApiError("invalid_request");
  return body;
}

me.put("/avatar", async (c) => {
  const body = await readAvatarJpeg(c);
  const userId = c.get("userId");
  const key = newId();
  await c.env.MEDIA.put(avatarObject(userId, key), body, {
    httpMetadata: { contentType: "image/jpeg" },
  });
  const old = await swapAvatar(c.env.DB, userId, key);
  if (old) await c.env.MEDIA.delete(avatarObject(userId, old)).catch(() => {});
  await notify(c.env, await familyPeers(c.env.DB, userId), { type: "profile", userId });
  return c.json({ avatarKey: key });
});

/** Removes the caller's profile photo. */
me.delete("/avatar", async (c) => {
  const userId = c.get("userId");
  const old = await swapAvatar(c.env.DB, userId, null);
  if (old) {
    await c.env.MEDIA.delete(avatarObject(userId, old)).catch(() => {});
    await notify(c.env, await familyPeers(c.env.DB, userId), { type: "profile", userId });
  }
  return c.body(null, 204);
});

/**
 * Deletes the caller's account (docs/protocol.md "Deleting an account"). The body must be
 * `{"confirm": "delete"}`. `last_admin` (409): the caller is the only admin and others are left.
 */
me.delete("/", async (c) => {
  if ((await readJson(c)).confirm !== "delete") throw new ApiError("invalid_request");
  const userId = c.get("userId");
  await deleteAccount(c.env, userId, userId);
  return c.body(null, 204);
});
