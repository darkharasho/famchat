import { Hono } from "hono";
import type { AppEnv } from "../env";
import { deleteAccount } from "../lib/delete-account";
import { newId } from "../lib/ids";
import { notify } from "../notify";
import { ApiError } from "../lib/errors";
import { readJson } from "../lib/validate";
import { requireAuth } from "../middleware/auth";

export const me = new Hono<AppEnv>();
me.use(requireAuth);

/** The signed-in user's profile. isAdmin comes from the database, not the access token. */
me.get("/", async (c) => {
  const row = await c.env.DB.prepare("SELECT name, is_admin, recovery_pub IS NOT NULL AS has_recovery FROM users WHERE id = ?")
    .bind(c.get("userId"))
    .first<{ name: string; is_admin: number; has_recovery: number }>();
  if (!row) throw new ApiError("unauthorized");
  return c.json({
    userId: c.get("userId"),
    deviceId: c.get("deviceId"),
    name: row.name,
    isAdmin: row.is_admin === 1,
    // An admin recovery key is registered (the printed code was saved).
    recoveryCodeSet: row.has_recovery === 1,
    // A reviewer account (docs/protocol.md "Reviewer accounts").
    reviewer: c.get("reviewer"),
    // KLIPY's terms have apps call it directly, so the app needs the key (null: GIFs are off).
    gifKey: c.env.KLIPY_APP_KEY || null,
  });
});

/** Largest profile photo (the app sends a 512 px JPEG, usually 30–80 KB). */
export const MAX_AVATAR_BYTES = 256 * 1024;

export const avatarObject = (userId: string, key: string) => `avatars/${userId}/${key}`;

const currentAvatar = (db: D1Database, userId: string) =>
  db.prepare("SELECT avatar_key FROM users WHERE id = ?").bind(userId).first<string | null>("avatar_key");

/** Everyone who sees [userId] in the directory: their side of the reviewer line. */
async function sameSide(db: D1Database, userId: string): Promise<string[]> {
  const { results } = await db.prepare(
    "SELECT id FROM users WHERE reviewer = (SELECT reviewer FROM users WHERE id = ?) AND deleted_at IS NULL",
  ).bind(userId).all<{ id: string }>();
  return results.map((r) => r.id);
}

/** Sets the caller's profile photo: the raw JPEG as the body. Answers the new avatarKey. */
me.put("/avatar", async (c) => {
  if (c.req.header("content-type") !== "image/jpeg") throw new ApiError("invalid_request");
  const body = new Uint8Array(await c.req.arrayBuffer());
  if (body.length > MAX_AVATAR_BYTES) throw new ApiError("too_large");
  if (body.length < 3 || body[0] !== 0xff || body[1] !== 0xd8 || body[2] !== 0xff) throw new ApiError("invalid_request");
  const userId = c.get("userId");
  const key = newId();
  await c.env.MEDIA.put(avatarObject(userId, key), body, {
    httpMetadata: { contentType: "image/jpeg" },
  });
  const old = await currentAvatar(c.env.DB, userId);
  await c.env.DB.prepare("UPDATE users SET avatar_key = ? WHERE id = ?").bind(key, userId).run();
  if (old) await c.env.MEDIA.delete(avatarObject(userId, old)).catch(() => {});
  await notify(c.env, await sameSide(c.env.DB, userId), { type: "profile", userId });
  return c.json({ avatarKey: key });
});

/** Removes the caller's profile photo. */
me.delete("/avatar", async (c) => {
  const userId = c.get("userId");
  const old = await currentAvatar(c.env.DB, userId);
  if (old) {
    await c.env.DB.prepare("UPDATE users SET avatar_key = NULL WHERE id = ?").bind(userId).run();
    await c.env.MEDIA.delete(avatarObject(userId, old)).catch(() => {});
    await notify(c.env, await sameSide(c.env.DB, userId), { type: "profile", userId });
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
