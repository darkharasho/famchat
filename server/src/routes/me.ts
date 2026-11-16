import { Hono } from "hono";
import type { AppEnv } from "../env";
import { ApiError } from "../lib/errors";
import { requireAuth } from "../middleware/auth";

export const me = new Hono<AppEnv>();
me.use(requireAuth);

/** The signed-in user's profile. isAdmin comes from the database, not the access token. */
me.get("/", async (c) => {
  const row = await c.env.DB.prepare("SELECT name, is_admin FROM users WHERE id = ?")
    .bind(c.get("userId"))
    .first<{ name: string; is_admin: number }>();
  if (!row) throw new ApiError("unauthorized");
  return c.json({ userId: c.get("userId"), deviceId: c.get("deviceId"), name: row.name, isAdmin: row.is_admin === 1 });
});
