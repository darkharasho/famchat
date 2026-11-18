// Account deletion (docs/protocol.md "Deleting an account"): DELETE /me and DELETE /admin/users/:id.
//
// In one transaction: the user row is anonymized (kept, so device certificates, reset history and
// old references still resolve), every device is revoked and renamed, the user leaves every chat
// (which moves each chat to a new epoch, as a leave does), and the messages they sent, the media
// they uploaded, their wraps, pairings, tickets and pending invites are deleted. Then the R2
// objects go, their sockets close, and the family is told.
import type { Env } from "../env";
import { hubStub } from "../hub";
import { notify } from "../notify";
import { memberIds } from "./chatdb";
import { ApiError } from "./errors";
import { familyPeers, NEXT_OWNER_SQL, notifyFamily, sharesChanged, sharingUserIds } from "./family";
import { eventStmt } from "./reset";

export const DELETED_USER_NAME = "Deleted user";
export const DELETED_DEVICE_NAME = "Deleted device";

export interface DeleteResult {
  revokedDevices: string[];
  chats: string[];
  messages: number;
  media: string[];
}

/** Binds the user id three times: the families where they are the only live admin and someone else is live. */
const SOLE_ADMIN_FAMILY_IDS = `SELECT m.family_id FROM family_members m
  WHERE m.user_id = ? AND m.role = 'admin'
    AND NOT EXISTS (SELECT 1 FROM family_members o JOIN users ou ON ou.id = o.user_id
      WHERE o.family_id = m.family_id AND o.user_id != ? AND o.role = 'admin' AND ou.deleted_at IS NULL)
    AND EXISTS (SELECT 1 FROM family_members o JOIN users ou ON ou.id = o.user_id
      WHERE o.family_id = m.family_id AND o.user_id != ? AND ou.deleted_at IS NULL)`;

/**
 * Deletes [userId]'s account. [actorId] is who asked (the user, or an admin). Throws `not_found`
 * for an unknown or already deleted user, and `last_admin` (with familyId and familyName) if they are
 * a family's only admin while anyone else in it is left (make someone else an admin first).
 */
export async function deleteAccount(env: Env, userId: string, actorId: string, now = Date.now()): Promise<DeleteResult> {
  const db = env.DB;
  // Who shares a chat with the user, before they leave them: they hear about the revoked devices.
  const sharing = (await sharingUserIds(db, userId)).filter((u) => u !== userId);

  const avatar = await db.prepare("SELECT avatar_key FROM users WHERE id = ?").bind(userId)
    .first<string | null>("avatar_key");

  // Everything after the first statement runs only if it marked the user deleted at [now].
  const guard = "EXISTS (SELECT 1 FROM users WHERE id = ? AND deleted_at = ?)";
  const gb = [userId, now];
  const stmts: D1PreparedStatement[] = [
    // The last admin of a family can't go while someone else in it is still here: it would have no
    // admin. Per family; deleted members don't count. Clears the operator flag too.
    db.prepare(
      `UPDATE users SET deleted_at = ?, name = ?, is_admin = 0, operator = 0, recovery_pub = NULL, recovery_sig = NULL,
         admin_by = NULL, admin_signer_pub = NULL, admin_sig = NULL, avatar_key = NULL
       WHERE id = ? AND deleted_at IS NULL AND NOT EXISTS (${SOLE_ADMIN_FAMILY_IDS})`,
    ).bind(now, DELETED_USER_NAME, userId, userId, userId, userId),
    // They stay in their families as plain members (so the directory still resolves them).
    db.prepare(
      `UPDATE family_members SET role = 'member', admin_by = NULL, admin_signer_pub = NULL, admin_sig = NULL
       WHERE user_id = ? AND ${guard}`,
    ).bind(userId, ...gb),
    db.prepare(
      `UPDATE devices SET revoked_at = ?, refresh_hash = NULL, prev_refresh_hash = NULL, push_token = NULL, push_previews = 0
       WHERE user_id = ? AND revoked_at IS NULL AND ${guard} RETURNING id`,
    ).bind(now, userId, ...gb),
    // Device names are often personal ("Mom's iPhone"); certificates don't cover them.
    db.prepare(`UPDATE devices SET name = ?, push_token = NULL, push_previews = 0 WHERE user_id = ? AND ${guard}`)
      .bind(DELETED_DEVICE_NAME, userId, ...gb),
    db.prepare(`DELETE FROM chat_key_wraps WHERE device_id IN (SELECT id FROM devices WHERE user_id = ?) AND ${guard}`)
      .bind(userId, ...gb),
    // Leaving: each chat moves to a new, not yet created epoch, which the remaining members create.
    db.prepare(
      `UPDATE chats SET current_epoch = current_epoch + 1
       WHERE id IN (SELECT chat_id FROM chat_members WHERE user_id = ?) AND ${guard} RETURNING id`,
    ).bind(userId, ...gb),
    db.prepare(`DELETE FROM chat_members WHERE user_id = ? AND ${guard}`).bind(userId, ...gb),
    db.prepare(`DELETE FROM messages WHERE sender_user_id = ? AND ${guard}`).bind(userId, ...gb),
    // Live rows lower media_usage through the delete trigger.
    db.prepare(`DELETE FROM media WHERE uploader_id = ? AND ${guard} RETURNING key, chat_id, expired_at`)
      .bind(userId, ...gb),
    db.prepare(
      `UPDATE pair_sessions SET cancelled_at = ?
       WHERE user_id = ? AND claimed_at IS NULL AND cancelled_at IS NULL AND ${guard}`,
    ).bind(now, userId, ...gb),
    // Their reset links (which would sign them in again) and invites they made stop working.
    db.prepare(
      `UPDATE invites SET expires_at = ?
       WHERE (user_id = ? OR created_by = ?) AND used_by IS NULL AND expires_at > ? AND ${guard}`,
    ).bind(now, userId, userId, now, ...gb),
    // The name an invite was made out to is the user's name too.
    db.prepare(`UPDATE invites SET name = ? WHERE (used_by = ? OR user_id = ?) AND ${guard}`)
      .bind(DELETED_USER_NAME, userId, userId, ...gb),
    db.prepare(`DELETE FROM ws_tickets WHERE user_id = ? AND ${guard}`).bind(userId, ...gb),
    // The families they own pass to their longest-serving other admin (or to no one).
    db.prepare(`UPDATE families SET created_by = ${NEXT_OWNER_SQL} WHERE created_by = ? AND ${guard} RETURNING id`)
      .bind(userId, userId, ...gb),
  ];
  const devIdx = 2, chatIdx = 5, msgIdx = 7, mediaIdx = 8, ownedIdx = 13;
  stmts.push(eventStmt(db, {
    kind: "account_deleted",
    userId,
    actorId,
    payload: { by: actorId === userId ? "self" : "admin" },
    at: now,
  }, { sql: guard, binds: gb }));

  const results = await db.batch(stmts);
  if (results[0].meta.changes !== 1) {
    const row = await db.prepare("SELECT deleted_at FROM users WHERE id = ?").bind(userId)
      .first<{ deleted_at: number | null }>();
    if (!row || row.deleted_at !== null) throw new ApiError("not_found");
    const fam = await db.prepare(
      `SELECT f.id AS familyId, f.name AS familyName FROM families f WHERE f.id IN (${SOLE_ADMIN_FAMILY_IDS}) ORDER BY f.id LIMIT 1`,
    ).bind(userId, userId, userId).first<{ familyId: number; familyName: string }>();
    throw new ApiError("last_admin", fam ? { familyId: fam.familyId, familyName: fam.familyName } : undefined);
  }
  // The hub forgets peer sets that still count the user.
  await sharesChanged(env);

  const revoked = (results[devIdx].results as { id: string }[]).map((r) => r.id);
  const chats = (results[chatIdx].results as { id: string }[]).map((r) => r.id);
  const media = results[mediaIdx].results as { key: string; chat_id: string; expired_at: number | null }[];

  const keys = [...media.map((m) => m.key), ...(avatar ? [`avatars/${userId}/${avatar}`] : [])];
  for (let i = 0; i < keys.length; i += 1000) {
    try {
      await env.MEDIA.delete(keys.slice(i, i + 1000));
    } catch (e) {
      // The rows are gone either way; an orphaned object only costs storage.
      console.error("R2 delete failed", e);
    }
  }
  for (const deviceId of revoked) {
    try {
      await hubStub(env).disconnectDevice(deviceId);
    } catch (e) {
      console.error("hub disconnect failed", e);
    }
  }
  for (const chatId of chats) await notify(env, await memberIds(db, chatId), { type: "chat", chatId });
  for (const deviceId of revoked) await notify(env, sharing, { type: "device", userId, deviceId, revoked: true });
  // Their photos and voice messages: shown as gone, like quota eviction.
  const byChat = new Map<string, string[]>();
  for (const m of media) if (m.expired_at === null) byChat.set(m.chat_id, [...(byChat.get(m.chat_id) ?? []), m.key]);
  for (const [chatId, ks] of byChat) await notify(env, await memberIds(db, chatId), { type: "media_expired", chatId, keys: ks });
  for (const { id } of results[ownedIdx].results as { id: number }[]) await notifyFamily(env, id);
  // Everyone who shared a family with them (their family_members rows stay, so this still works).
  await notify(env, await familyPeers(db, userId), { type: "account_deleted", userId });

  return { revokedDevices: revoked, chats, messages: results[msgIdx].meta.changes, media: keys };
}
