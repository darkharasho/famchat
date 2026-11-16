import { Hono } from "hono";
import type { AppEnv } from "../env";
import { deleteAccount } from "../lib/delete-account";
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
  });
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
