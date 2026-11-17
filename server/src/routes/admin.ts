import { Hono } from "hono";
import type { AppEnv, Env } from "../env";
import { isUlid } from "../lib/chatdb";
import { ApiError } from "../lib/errors";
import { FAMILY_ONE, REVIEWER_FAMILY } from "../lib/family";
import { MEDIA_CAP, MEDIA_TARGET, mediaUsage } from "../lib/media";
import { freshTime, logEvent, promotionMessage, pubKey, recoveryKeyMessage, resetMessage, signature, verifyEd25519 } from "../lib/reset";
import { deleteAccount } from "../lib/delete-account";
import { resetAccount } from "../lib/reset-account";
import { randomToken, sha256Hex } from "../lib/tokens";
import { name, readJson } from "../lib/validate";
import { bearer, requireAdmin, requireAnyAdmin, requireOperator, requireAuth } from "../middleware/auth";

export const INVITE_TTL_MS = 7 * 24 * 60 * 60 * 1000;

async function timingSafeEqual(a: string, b: string): Promise<boolean> {
  const [ha, hb] = await Promise.all([sha256Hex(a), sha256Hex(b)]);
  let diff = 0;
  for (let i = 0; i < ha.length; i++) diff |= ha.charCodeAt(i) ^ hb.charCodeAt(i);
  return diff === 0;
}

export function inviteUrl(env: Env, token: string): string {
  return `${env.APP_ORIGIN}/join#${token}`;
}

/**
 * A reviewer invite's link carries a `review.` marker, so the app asks the reviewer for a display
 * name (a normal invite already has the name the admin gave it). Tokens are at least 20 characters,
 * so the marker can't be mistaken for one.
 */
export function reviewerInviteUrl(env: Env, token: string): string {
  return `${env.APP_ORIGIN}/join#review.${token}`;
}

/** Reviewer invites never expire on their own (only by revocation): year 9999. */
export const NEVER = 253_402_300_799_999;

/**
 * Bootstrap invites (createdBy = null) are only inserted while family #1 has no live member and no
 * live operator exists, in the same statement. Reviewer accounts don't count. Invites are for family #1.
 */
async function createInvite(env: Env, inviteName: string, makeAdmin: boolean, createdBy: string | null) {
  const token = randomToken();
  const now = Date.now();
  const expiresAt = now + INVITE_TTL_MS;
  const res = await env.DB.prepare(
    `INSERT INTO invites (token_hash, name, make_admin, created_by, created_at, expires_at, family_id)
     SELECT ?, ?, ?, ?, ?, ?, ${FAMILY_ONE} WHERE ? IS NOT NULL
       OR (NOT EXISTS (SELECT 1 FROM family_members m JOIN users u ON u.id = m.user_id
                       WHERE m.family_id = ${FAMILY_ONE} AND u.deleted_at IS NULL)
           AND NOT EXISTS (SELECT 1 FROM users WHERE operator = 1 AND deleted_at IS NULL))`,
  )
    .bind(await sha256Hex(token), inviteName, makeAdmin ? 1 : 0, createdBy, now, expiresAt, createdBy)
    .run();
  if (res.meta.changes !== 1) throw new ApiError("already_bootstrapped");
  return { inviteToken: token, inviteUrl: inviteUrl(env, token), expiresAt };
}

export const admin = new Hono<AppEnv>();

admin.post("/bootstrap", async (c) => {
  const secret = bearer(c.req.header("authorization"));
  if (!secret || !c.env.BOOTSTRAP_SECRET || !(await timingSafeEqual(secret, c.env.BOOTSTRAP_SECRET))) {
    throw new ApiError("unauthorized");
  }
  const inviteName = name((await readJson(c)).name, 40);
  return c.json(await createInvite(c.env, inviteName, true, null), 201);
});

admin.post("/invites", requireAuth, requireAdmin, async (c) => {
  const inviteName = name((await readJson(c)).name, 40);
  return c.json(await createInvite(c.env, inviteName, false, c.get("userId")), 201);
});

/** The active reviewer invite: not revoked and not expired (its creator's deletion expires it). */
const ACTIVE_REVIEWER_INVITE = "reviewer = 1 AND revoked_at IS NULL AND expires_at > ?";

/**
 * Creates the reviewer invite (docs/protocol.md "Reviewer accounts"): reusable, never expiring,
 * revocable. At most one is active, so an earlier one is revoked in the same transaction.
 */
admin.post("/reviewer-invite", requireAuth, requireOperator, async (c) => {
  const db = c.env.DB;
  const token = randomToken();
  const now = Date.now();
  await db.batch([
    db.prepare(`UPDATE invites SET revoked_at = ? WHERE ${ACTIVE_REVIEWER_INVITE}`).bind(now, now),
    db.prepare(
      `INSERT INTO invites (token_hash, name, make_admin, created_by, created_at, expires_at, reviewer, token, family_id)
       VALUES (?, 'Reviewer', 0, ?, ?, ?, 1, ?, ${REVIEWER_FAMILY})`,
    ).bind(await sha256Hex(token), c.get("userId"), now, NEVER, token),
  ]);
  return c.json({ inviteToken: token, inviteUrl: reviewerInviteUrl(c.env, token), createdAt: now }, 201);
});

/** Revokes the reviewer invite: redeeming it fails from now on. Reviewer accounts stay. */
admin.delete("/reviewer-invite", requireAuth, requireOperator, async (c) => {
  const now = Date.now();
  await c.env.DB.prepare(`UPDATE invites SET revoked_at = ? WHERE ${ACTIVE_REVIEWER_INVITE}`).bind(now, now).run();
  return c.body(null, 204);
});

/** The active reviewer invite's link (or null) and the reviewer accounts, which GET /users never lists for the family. */
admin.get("/reviewers", requireAuth, requireOperator, async (c) => {
  const db = c.env.DB;
  const now = Date.now();
  const [inv, users] = await db.batch([
    db.prepare(`SELECT token, created_at FROM invites WHERE ${ACTIVE_REVIEWER_INVITE} ORDER BY created_at DESC LIMIT 1`).bind(now),
    db.prepare(
      `SELECT u.id, u.name, u.created_at,
         (SELECT COUNT(*) FROM devices d WHERE d.user_id = u.id AND d.revoked_at IS NULL) AS devices
       FROM users u JOIN family_members m ON m.user_id = u.id AND m.family_id = ?
       WHERE u.deleted_at IS NULL ORDER BY u.created_at, u.id`,
    ).bind(REVIEWER_FAMILY),
  ]);
  const i = inv.results[0] as { token: string; created_at: number } | undefined;
  type U = { id: string; name: string; created_at: number; devices: number };
  return c.json({
    invite: i ? { inviteUrl: reviewerInviteUrl(c.env, i.token), createdAt: i.created_at } : null,
    users: (users.results as U[]).map((u) => ({ id: u.id, name: u.name, createdAt: u.created_at, devices: u.devices })),
  });
});

/** Media storage: live bytes against the cap, and how many objects are live or expired. */
admin.get("/usage", requireAuth, requireAdmin, async (c) => {
  const counts = await c.env.DB.prepare(
    "SELECT COALESCE(SUM(expired_at IS NULL), 0) AS live, COALESCE(SUM(expired_at IS NOT NULL), 0) AS expired FROM media",
  ).first<{ live: number; expired: number }>();
  return c.json({
    usedBytes: await mediaUsage(c.env.DB),
    capBytes: MEDIA_CAP,
    evictToBytes: MEDIA_TARGET,
    files: counts?.live ?? 0,
    expiredFiles: counts?.expired ?? 0,
  });
});

/**
 * Resets a user who lost every device. The body is a statement signed by the caller's identity key
 * (docs/protocol.md "Account resets"). Their devices are revoked and their chats rotated at once;
 * the returned one-time link signs them in again with a new identity key on the same account.
 */
admin.post("/users/:id/reset", requireAuth, requireAdmin, async (c) => {
  const db = c.env.DB;
  const userId = c.req.param("id");
  const adminId = c.get("userId");
  const body = await readJson(c);
  const now = Date.now();
  const resetId = body.resetId;
  if (!isUlid(resetId)) throw new ApiError("invalid_request");
  const oldIdentityPub = pubKey(body.oldIdentityPub);
  const claimPub = pubKey(body.claimPub);
  const sig = signature(body.sig);
  const createdAt = freshTime(body.createdAt, now);
  if (userId === adminId) throw new ApiError("invalid_request");

  const [target, signer] = await Promise.all([
    // Only members of family #1 are reset (reviewers aren't in it: the operator removes them instead).
    db.prepare(
      `SELECT u.name, u.identity_pub FROM users u
       WHERE u.id = ? AND u.deleted_at IS NULL
         AND EXISTS (SELECT 1 FROM family_members m WHERE m.family_id = ? AND m.user_id = u.id)`,
    ).bind(userId, FAMILY_ONE)
      .first<{ name: string; identity_pub: string }>(),
    db.prepare("SELECT identity_pub FROM users WHERE id = ?").bind(adminId).first<string>("identity_pub"),
  ]);
  if (!target) throw new ApiError("not_found");
  if (!signer) throw new ApiError("unauthorized");
  const statement = { resetId, userId, signerUserId: adminId, signerKind: "admin" as const, oldIdentityPub, claimPub, createdAt };
  if (!(await verifyEd25519(signer, sig, resetMessage(statement)))) throw new ApiError("invalid_request");
  if (oldIdentityPub !== target.identity_pub) throw new ApiError("conflict");

  const token = randomToken();
  const expiresAt = now + INVITE_TTL_MS;
  await resetAccount(c.env, {
    statement,
    sig,
    signerPub: signer,
    recoverySig: null,
    actorId: adminId,
    now,
    invite: { tokenHash: await sha256Hex(token), name: target.name, createdBy: adminId, expiresAt },
  });
  return c.json({ resetId, inviteToken: token, inviteUrl: inviteUrl(c.env, token), expiresAt }, 201);
});

/**
 * Makes another member an admin (the second admin the setup flow asks for). `sig` is the caller's
 * identity key over `"famchat-admin-v1" ‖ str(userId) ‖ str(callerId)`, so other devices can check
 * that an admin they trust made the promotion.
 */
admin.post("/users/:id/admin", requireAuth, requireAdmin, async (c) => {
  const db = c.env.DB;
  const userId = c.req.param("id");
  const by = c.get("userId");
  const sig = signature((await readJson(c)).sig);
  const signer = await db.prepare("SELECT identity_pub FROM users WHERE id = ?").bind(by).first<string>("identity_pub");
  if (!signer || !(await verifyEd25519(signer, sig, promotionMessage(userId, by)))) throw new ApiError("invalid_request");
  // The target must be a live member of family #1; checked first so nothing is half-written.
  const member = await db.prepare(
    `SELECT 1 AS ok FROM family_members m JOIN users u ON u.id = m.user_id
     WHERE m.family_id = ? AND m.user_id = ? AND u.deleted_at IS NULL`,
  ).bind(FAMILY_ONE, userId).first();
  if (!member) throw new ApiError("not_found");
  await db.batch([
    db.prepare(
      "UPDATE family_members SET role = 'admin', admin_by = ?, admin_signer_pub = ?, admin_sig = ? WHERE family_id = ? AND user_id = ?",
    ).bind(by, signer, sig, FAMILY_ONE, userId),
    db.prepare("UPDATE users SET is_admin = 1, admin_by = ?, admin_signer_pub = ?, admin_sig = ? WHERE id = ?")
      .bind(by, signer, sig, userId),
  ]);
  await logEvent(db, { kind: "admin_promoted", userId, actorId: by });
  return c.body(null, 204);
});

/**
 * Registers the public half of the caller's admin recovery key (derived on their device from a
 * printed code the server never sees), signed by their identity key. Replaces an earlier one.
 */
admin.post("/recovery-key", requireAuth, requireAnyAdmin, async (c) => {
  const db = c.env.DB;
  const userId = c.get("userId");
  const body = await readJson(c);
  const recoveryPub = pubKey(body.recoveryPub);
  const sig = signature(body.sig);
  const identityPub = await db.prepare("SELECT identity_pub FROM users WHERE id = ?").bind(userId).first<string>("identity_pub");
  if (!identityPub || !(await verifyEd25519(identityPub, sig, recoveryKeyMessage(userId, recoveryPub)))) {
    throw new ApiError("invalid_request");
  }
  try {
    await db.prepare("UPDATE users SET recovery_pub = ?, recovery_sig = ? WHERE id = ?").bind(recoveryPub, sig, userId).run();
  } catch (e) {
    if (String(e).includes("UNIQUE")) throw new ApiError("conflict");
    throw e;
  }
  await logEvent(db, { kind: "recovery_key_set", userId, actorId: userId });
  return c.body(null, 204);
});

/**
 * Removes another account: deletes it exactly as DELETE /me does (docs/protocol.md "Deleting an
 * account"), for someone who asked to be removed or who is gone. Operator only, as it reaches
 * across families. Yourself: use DELETE /me.
 */
admin.delete("/users/:id", requireAuth, requireOperator, async (c) => {
  const userId = c.req.param("id");
  const adminId = c.get("userId");
  if (userId === adminId) throw new ApiError("invalid_request");
  await deleteAccount(c.env, userId, adminId);
  return c.body(null, 204);
});
