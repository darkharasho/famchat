import { Hono } from "hono";
import type { AppEnv } from "../env";
import { ApiError } from "../lib/errors";
import { hubStub } from "../hub";
import { memberIds } from "../lib/chatdb";
import { sharingUserIds } from "../lib/family";
import { logEvent } from "../lib/reset";
import { requireAuth } from "../middleware/auth";
import { notify } from "../notify";

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

/**
 * Revokes one of the caller's devices. Every chat of the user moves to a new, not yet created
 * epoch (in the same transaction), so the revoked device's keys can't read what comes next; the
 * first member device to see the `chat` event creates the epoch without it.
 */
devices.delete("/:id", async (c) => {
  const db = c.env.DB;
  const id = c.req.param("id");
  const userId = c.get("userId");
  const now = Date.now();
  const [res, bumped] = await db.batch([
    db.prepare(
      `UPDATE devices SET revoked_at = ?, refresh_hash = NULL, prev_refresh_hash = NULL, push_token = NULL
       WHERE id = ? AND user_id = ? AND revoked_at IS NULL`,
    ).bind(now, id, userId),
    db.prepare(
      `UPDATE chats SET current_epoch = current_epoch + 1
       WHERE id IN (SELECT chat_id FROM chat_members WHERE user_id = ?)
         AND EXISTS (SELECT 1 FROM devices WHERE id = ? AND revoked_at = ? AND user_id = ?)
       RETURNING id`,
    ).bind(userId, id, now, userId),
    // Pairings this device approved but that weren't claimed yet die with it (a stolen phone
    // approving the thief's laptop).
    db.prepare(
      `UPDATE pair_sessions SET cancelled_at = ?
       WHERE approved_by_device = ? AND claimed_at IS NULL AND cancelled_at IS NULL
         AND EXISTS (SELECT 1 FROM devices WHERE id = ? AND revoked_at = ? AND user_id = ?)`,
    ).bind(now, id, id, now, userId),
  ]);
  if (res.meta.changes !== 1) throw new ApiError("not_found");
  await logEvent(db, { kind: "device_revoked", userId, actorId: userId, payload: { deviceId: id }, at: now });
  try {
    await hubStub(c.env).disconnectDevice(id);
  } catch (e) {
    console.error("hub disconnect failed", e);
  }
  for (const { id: chatId } of bumped.results as { id: string }[]) {
    await notify(c.env, await memberIds(db, chatId), { type: "chat", chatId });
  }
  await notify(c.env, await sharingUserIds(db, userId), { type: "device", userId, deviceId: id, revoked: true });
  return c.body(null, 204);
});
