import { Hono } from "hono";
import type { AppEnv } from "../env";
import { parseWraps, wrapInserts, wrapOut } from "../lib/chatdb";
import { ApiError } from "../lib/errors";
import { readJson } from "../lib/validate";
import { requireAuth } from "../middleware/auth";
import { notify } from "../notify";

export const keys = new Hono<AppEnv>();
keys.use(requireAuth);

/** Wrapped chat keys addressed to this device, for chats its user is still in. */
keys.get("/wraps", async (c) => {
  const chatId = c.req.query("chatId");
  const { results } = await c.env.DB.prepare(
    `SELECT w.chat_id, w.epoch, w.device_id, w.wrapper_device_id, w.sealed, w.sig FROM chat_key_wraps w
     JOIN chat_members m ON m.chat_id = w.chat_id AND m.user_id = ?
     WHERE w.device_id = ? AND (? IS NULL OR w.chat_id = ?) ORDER BY w.chat_id, w.epoch`,
  ).bind(c.get("userId"), c.get("deviceId"), chatId ?? null, chatId ?? null)
    .all<{ chat_id: string; epoch: number; device_id: string; wrapper_device_id: string; sealed: string; sig: string }>();
  return c.json({ wraps: results.map(wrapOut) });
});

/**
 * Member devices without a wrap for an epoch, limited to (chat, epoch) pairs this device holds a
 * wrap for, so it can add them ("missing-wrap repair").
 */
keys.get("/missing", async (c) => {
  const { results } = await c.env.DB.prepare(
    `SELECT w.chat_id AS chatId, w.epoch AS epoch, d.id AS deviceId FROM chat_key_wraps w
     JOIN chat_members me ON me.chat_id = w.chat_id AND me.user_id = ?
     JOIN chat_members m ON m.chat_id = w.chat_id
     JOIN devices d ON d.user_id = m.user_id AND d.revoked_at IS NULL
     WHERE w.device_id = ?
       AND NOT EXISTS (SELECT 1 FROM chat_key_wraps x WHERE x.chat_id = w.chat_id AND x.epoch = w.epoch AND x.device_id = d.id)
     ORDER BY w.chat_id, w.epoch, d.id`,
  ).bind(c.get("userId"), c.get("deviceId")).all<{ chatId: string; epoch: number; deviceId: string }>();
  return c.json({ missing: results });
});

/** Adds wraps for devices that lack them. Existing wraps are never replaced. */
keys.put("/wraps", async (c) => {
  const db = c.env.DB;
  const me = c.get("userId");
  const device = c.get("deviceId");
  const wraps = parseWraps((await readJson(c)).wraps);
  if (wraps.length === 0) throw new ApiError("invalid_request");
  const chatIds = [...new Set(wraps.map((w) => w.chatId))];
  const recipients = new Map<string, Set<string>>(); // chatId -> live devices of current members
  const deviceUser = new Map<string, string>();
  const epochs = new Map<string, Set<number>>();
  for (const chatId of chatIds) {
    const [mem, devs, eps] = await db.batch([
      db.prepare("SELECT 1 FROM chat_members WHERE chat_id = ? AND user_id = ?").bind(chatId, me),
      db.prepare(
        `SELECT d.id, d.user_id FROM devices d JOIN chat_members m ON m.user_id = d.user_id
         WHERE m.chat_id = ? AND d.revoked_at IS NULL`,
      ).bind(chatId),
      db.prepare("SELECT epoch FROM chat_epochs WHERE chat_id = ?").bind(chatId),
    ]);
    if (mem.results.length === 0) throw new ApiError("invalid_request");
    const set = new Set<string>();
    for (const d of devs.results as { id: string; user_id: string }[]) {
      set.add(d.id);
      deviceUser.set(d.id, d.user_id);
    }
    recipients.set(chatId, set);
    epochs.set(chatId, new Set((eps.results as { epoch: number }[]).map((e) => e.epoch)));
  }
  for (const w of wraps) {
    if (w.wrapperDeviceId !== device) throw new ApiError("invalid_request");
    if (!epochs.get(w.chatId)!.has(w.epoch)) throw new ApiError("invalid_request");
    if (!recipients.get(w.chatId)!.has(w.recipientDeviceId)) throw new ApiError("invalid_request");
  }
  const results = await db.batch(wrapInserts(db, wraps, Date.now()));
  const added = results.filter((r) => r.meta.changes === 1).length;
  if (added > 0) {
    for (const chatId of chatIds) {
      const users = [...new Set(wraps.filter((w, i) => w.chatId === chatId && results[i].meta.changes === 1)
        .map((w) => deviceUser.get(w.recipientDeviceId)!))];
      if (users.length) await notify(c.env, users, { type: "keys", chatId });
    }
  }
  return c.json({ added });
});
