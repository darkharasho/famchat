import { Hono } from "hono";
import type { AppEnv, Env } from "../env";
import { isUlid } from "../lib/chatdb";
import { ApiError } from "../lib/errors";
import { MEDIA_CAP, MEDIA_TARGET, mediaUsage } from "../lib/media";
import { freshTime, logEvent, pubKey, recoveryKeyMessage, resetMessage, signature, verifyEd25519 } from "../lib/reset";
import { resetAccount } from "../lib/reset-account";
import { randomToken, sha256Hex } from "../lib/tokens";
import { name, readJson } from "../lib/validate";
import { bearer, requireAdmin, requireAuth } from "../middleware/auth";

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

/** Bootstrap invites (createdBy = null) are only inserted while no user exists, in the same statement. */
async function createInvite(env: Env, inviteName: string, makeAdmin: boolean, createdBy: string | null) {
  const token = randomToken();
  const now = Date.now();
  const expiresAt = now + INVITE_TTL_MS;
  const res = await env.DB.prepare(
    `INSERT INTO invites (token_hash, name, make_admin, created_by, created_at, expires_at)
     SELECT ?, ?, ?, ?, ?, ? WHERE ? IS NOT NULL OR NOT EXISTS (SELECT 1 FROM users)`,
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
    db.prepare("SELECT name, identity_pub FROM users WHERE id = ?").bind(userId).first<{ name: string; identity_pub: string }>(),
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

/** Makes another member an admin (the second admin the setup flow asks for). */
admin.post("/users/:id/admin", requireAuth, requireAdmin, async (c) => {
  const userId = c.req.param("id");
  const res = await c.env.DB.prepare("UPDATE users SET is_admin = 1 WHERE id = ?").bind(userId).run();
  if (res.meta.changes !== 1) throw new ApiError("not_found");
  await logEvent(c.env.DB, { kind: "admin_promoted", userId, actorId: c.get("userId") });
  return c.body(null, 204);
});

/**
 * Registers the public half of the caller's admin recovery key (derived on their device from a
 * printed code the server never sees), signed by their identity key. Replaces an earlier one.
 */
admin.post("/recovery-key", requireAuth, requireAdmin, async (c) => {
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
