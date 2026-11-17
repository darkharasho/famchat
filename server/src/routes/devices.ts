import { Hono } from "hono";
import type { AppEnv } from "../env";
import { ApiError } from "../lib/errors";
import { hubStub } from "../hub";
import { memberIds } from "../lib/chatdb";
import { sharingUserIds } from "../lib/family";
import { logEvent } from "../lib/reset";
import { readJson } from "../lib/validate";
import { requireAuth } from "../middleware/auth";
import { notify } from "../notify";
import { type Delivery, sendAll, serviceAccount } from "../push/consumer";

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
 * Sets (or with null, clears) this device's FCM token and, optionally, whether its pushes carry the
 * envelope for an on-device preview (kept when omitted, reset to off when the token is cleared). A
 * token belongs to one app install, so it is taken away from any other device row that still had it
 * (an app signed in again).
 */
devices.put("/me/push", async (c) => {
  const body = await readJson(c);
  const token = body.token;
  if (token !== null && (typeof token !== "string" || token.length < 1 || token.length > 4096)) {
    throw new ApiError("invalid_request");
  }
  const previews = body.previews;
  if (previews !== undefined && typeof previews !== "boolean") throw new ApiError("invalid_request");
  const previewsBind = previews === undefined ? null : previews ? 1 : 0;
  const db = c.env.DB;
  const deviceId = c.get("deviceId");
  await db.batch([
    db.prepare("UPDATE devices SET push_token = NULL, push_previews = 0 WHERE push_token = ? AND id != ?").bind(token, deviceId),
    db.prepare(
      "UPDATE devices SET push_token = ?, push_previews = CASE WHEN ? IS NULL THEN 0 ELSE COALESCE(?, push_previews) END WHERE id = ?",
    ).bind(token, token, previewsBind, deviceId),
  ]);
  return c.body(null, 204);
});

/**
 * Sends a test notification to the caller's own devices that have a token, right away, and says
 * how each went. For checking the Firebase setup (scripts/setup-firebase.sh).
 */
devices.post("/me/push/test", async (c) => {
  const sa = serviceAccount(c.env);
  if (!sa) return c.json({ configured: false, devices: [] });
  const { results } = await c.env.DB.prepare(
    `SELECT id, name, push_token FROM devices WHERE user_id = ? AND revoked_at IS NULL AND push_token IS NOT NULL`,
  ).bind(c.get("userId")).all<{ id: string; name: string; push_token: string }>();
  const names = new Map(results.map((d) => [d.id, d.name]));
  let sent: Delivery[];
  try {
    sent = await sendAll(c.env, sa, results, { title: "FamChat", body: "Test notification", chatId: null }, (i, init) => fetch(i, init));
  } catch (e) {
    console.error("push test failed", e);
    return c.json({ configured: true, error: "oauth_failed", devices: [] });
  }
  return c.json({ configured: true, devices: sent.map((d) => ({ id: d.deviceId, name: names.get(d.deviceId), result: d.result })) });
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
      `UPDATE devices SET revoked_at = ?, refresh_hash = NULL, prev_refresh_hash = NULL, push_token = NULL, push_previews = 0
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
