// The transaction behind an admin reset and an admin recovery: record the signed reset, sign out
// every device of the user, move each of their chats to a new epoch, cancel their pending
// pairings and older reset links, then tell the family.
import type { Env } from "../env";
import { hubStub } from "../hub";
import { notify } from "../notify";
import { memberIds } from "./chatdb";
import { ApiError } from "./errors";
import { sharingUserIds } from "./family";
import { eventStmt, type ResetStatement } from "./reset";

export interface ResetPlan {
  statement: ResetStatement;
  sig: string;
  signerPub: string;
  recoverySig: string | null;
  actorId: string | null;
  now: number;
  /** Admin reset: the one-time link that signs the user in again. */
  invite?: { tokenHash: string; name: string; createdBy: string; expiresAt: number };
  /**
   * Recovery: the new identity key and device go in in the same transaction, and only if the
   * user's recovery key is still [recoveryPub] and their identity key still the statement's.
   */
  recovered?: {
    recoveryPub: string;
    newIdentityPub: string;
    claimSig: string;
    device: { id: string; name: string; platform: string; encPub: string; signPub: string; certSig: string; refreshHash: string };
  };
}

/** Runs the reset; returns false if a recovery's guard failed (nothing changed). */
export async function resetAccount(env: Env, p: ResetPlan): Promise<boolean> {
  const db = env.DB;
  const s = p.statement;
  const userId = s.userId;
  const now = p.now;
  const r = p.recovered;
  // A recovery first swaps the identity key, guarded by the recovery key still being registered.
  // The reset row is written only if that swap just happened, and everything after it only if
  // the reset row (with this batch's completion time) exists, so a failed guard changes nothing.
  const rowGuard = r ? "EXISTS (SELECT 1 FROM users WHERE id = ? AND identity_pub = ? AND recovery_pub IS NULL)" : "1";
  const rowBinds = r ? [userId, r.newIdentityPub] : [];
  const guard = r ? "EXISTS (SELECT 1 FROM resets WHERE id = ? AND completed_at = ?)" : "1";
  const gb = r ? [s.resetId, now] : [];

  const stmts: D1PreparedStatement[] = [];
  if (r) {
    stmts.push(db.prepare(
      `UPDATE users SET identity_pub = ?, recovery_pub = NULL, recovery_sig = NULL
       WHERE id = ? AND recovery_pub = ? AND identity_pub = ?`,
    ).bind(r.newIdentityPub, userId, r.recoveryPub, s.oldIdentityPub));
  }
  stmts.push(db.prepare(
    `INSERT INTO resets (id, user_id, signer_user_id, signer_kind, signer_pub, recovery_sig, old_identity_pub, claim_pub,
       created_at, sig, new_identity_pub, claim_sig, completed_at)
     SELECT ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ? WHERE ${rowGuard}`,
  ).bind(
    s.resetId, userId, s.signerUserId, s.signerKind, p.signerPub, p.recoverySig, s.oldIdentityPub, s.claimPub,
    s.createdAt, p.sig, r?.newIdentityPub ?? null, r?.claimSig ?? null, r ? now : null, ...rowBinds,
  ));
  // Older reset links for this user stop working.
  stmts.push(db.prepare(
    `UPDATE invites SET expires_at = ? WHERE user_id = ? AND used_by IS NULL AND expires_at > ? AND ${guard}`,
  ).bind(now, userId, now, ...gb));
  if (p.invite) {
    stmts.push(db.prepare(
      `INSERT INTO invites (token_hash, name, make_admin, created_by, created_at, expires_at, user_id, reset_id)
       VALUES (?, ?, 0, ?, ?, ?, ?, ?)`,
    ).bind(p.invite.tokenHash, p.invite.name, p.invite.createdBy, now, p.invite.expiresAt, userId, s.resetId));
  }
  const revokeIdx = stmts.length;
  stmts.push(db.prepare(
    `UPDATE devices SET revoked_at = ?, refresh_hash = NULL, prev_refresh_hash = NULL, push_token = NULL
     WHERE user_id = ? AND revoked_at IS NULL AND ${guard} RETURNING id`,
  ).bind(now, userId, ...gb));
  const bumpIdx = stmts.length;
  stmts.push(db.prepare(
    `UPDATE chats SET current_epoch = current_epoch + 1
     WHERE id IN (SELECT chat_id FROM chat_members WHERE user_id = ?) AND ${guard} RETURNING id`,
  ).bind(userId, ...gb));
  stmts.push(db.prepare(
    `UPDATE pair_sessions SET cancelled_at = ?
     WHERE user_id = ? AND claimed_at IS NULL AND cancelled_at IS NULL AND ${guard}`,
  ).bind(now, userId, ...gb));
  if (r) {
    const d = r.device;
    stmts.push(db.prepare(
      `INSERT INTO devices (id, user_id, name, platform, enc_pub, sign_pub, cert_sig, refresh_hash, created_at, last_seen)
       SELECT ?, ?, ?, ?, ?, ?, ?, ?, ?, ? WHERE ${guard}`,
    ).bind(d.id, userId, d.name, d.platform, d.encPub, d.signPub, d.certSig, d.refreshHash, now, now, ...gb));
  }
  stmts.push(eventStmt(db, {
    kind: r ? "recovered" : "reset",
    userId,
    actorId: p.actorId,
    payload: { resetId: s.resetId, ...(r ? { deviceId: r.device.id } : {}) },
    at: now,
  }, { sql: guard, binds: gb }));

  let results: D1Result[];
  try {
    results = await db.batch(stmts);
  } catch (e) {
    if (String(e).includes("UNIQUE") || String(e).includes("PRIMARY KEY")) throw new ApiError("conflict");
    throw e;
  }
  if (r && results[0].meta.changes !== 1) return false;

  const revoked = (results[revokeIdx].results as { id: string }[]).map((x) => x.id);
  const bumped = (results[bumpIdx].results as { id: string }[]).map((x) => x.id);
  for (const deviceId of revoked) {
    try {
      await hubStub(env).disconnectDevice(deviceId);
    } catch (e) {
      console.error("hub disconnect failed", e);
    }
  }
  for (const chatId of bumped) await notify(env, await memberIds(db, chatId), { type: "chat", chatId });
  const sharing = await sharingUserIds(db, userId);
  for (const deviceId of revoked) await notify(env, sharing, { type: "device", userId, deviceId, revoked: true });
  if (r) await notify(env, sharing, { type: "device", userId, deviceId: r.device.id });
  await notifyReset(env, userId, s.resetId);
  return true;
}

/** Every family member refreshes the directory and checks the reset. */
export async function notifyReset(env: Env, userId: string, resetId: string): Promise<void> {
  const { results } = await env.DB.prepare("SELECT id FROM users").all<{ id: string }>();
  await notify(env, results.map((u) => u.id), { type: "reset", userId, resetId });
}
