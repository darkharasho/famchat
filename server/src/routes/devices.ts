import { Hono } from "hono";
import type { AppEnv } from "../env";
import { ApiError } from "../lib/errors";
import { requireAuth } from "../middleware/auth";

export const devices = new Hono<AppEnv>();
devices.use(requireAuth);

devices.get("/", async (c) => {
  const { results } = await c.env.DB.prepare(
    `SELECT id, name, platform, created_at, last_seen FROM devices
     WHERE user_id = ? AND revoked_at IS NULL ORDER BY created_at`,
  )
    .bind(c.get("userId"))
    .all<{ id: string; name: string; platform: string; created_at: number; last_seen: number }>();
  const current = c.get("deviceId");
  return c.json({
    devices: results.map((d) => ({
      id: d.id,
      name: d.name,
      platform: d.platform,
      createdAt: d.created_at,
      lastSeen: d.last_seen,
      current: d.id === current,
    })),
  });
});

devices.delete("/:id", async (c) => {
  const res = await c.env.DB.prepare(
    `UPDATE devices SET revoked_at = ?, refresh_hash = NULL, push_token = NULL
     WHERE id = ? AND user_id = ? AND revoked_at IS NULL`,
  )
    .bind(Date.now(), c.req.param("id"), c.get("userId"))
    .run();
  if (res.meta.changes !== 1) throw new ApiError("not_found");
  return c.body(null, 204);
});
