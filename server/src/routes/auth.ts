import { Hono } from "hono";
import type { AppEnv, Env } from "../env";
import { isUlid } from "../lib/chatdb";
import { verifyDeviceCert } from "../lib/devicecert";
import { ApiError } from "../lib/errors";
import { FAMILY_ONE, REVIEWER_FAMILY, sharesChanged, sharingUserIds } from "../lib/family";
import { newId } from "../lib/ids";
import { claimMessage, eventStmt, freshTime, pubKey, recoveryKeyMessage, resetMessage, signature, verifyEd25519 } from "../lib/reset";
import { notifyReset, resetAccount } from "../lib/reset-account";
import { randomToken, sha256Hex, signAccessToken } from "../lib/tokens";
import { name, readJson, str } from "../lib/validate";
import { notify } from "../notify";

export const PLATFORMS = ["ios", "android", "macos", "windows", "linux", "web"] as const;

export const auth = new Hono<AppEnv>();

export const REDEEM_RETRY_MS = 10 * 60 * 1000;
export const REFRESH_GRACE_MS = 60 * 1000;

function assertConfigured(env: Env): void {
  if (!env.TOKEN_SECRET) throw new ApiError("internal");
}

/** A new device's name, platform and certified keys from a sign-in body; the cert must verify. */
async function newDeviceKeys(body: Record<string, unknown>) {
  const deviceName = name(body.deviceName, 60);
  const platform = str(body.platform);
  if (!(PLATFORMS as readonly string[]).includes(platform)) throw new ApiError("invalid_request");
  const identityPub = str(body.identityPub);
  const encPub = str(body.encPub);
  const signPub = str(body.signPub);
  const certSig = str(body.certSig);
  if (!(await verifyDeviceCert(identityPub, encPub, signPub, certSig))) {
    throw new ApiError("invalid_request");
  }
  return { deviceName, platform, identityPub, encPub, signPub, certSig };
}

type Keys = Awaited<ReturnType<typeof newDeviceKeys>>;

auth.post("/invite/redeem", async (c) => {
  assertConfigured(c.env);
  const body = await readJson(c);
  const token = str(body.token);
  const k = await newDeviceKeys(body);
  const { deviceName, platform, identityPub, encPub, signPub, certSig } = k;

  const tokenHash = await sha256Hex(token);
  const db = c.env.DB;
  const invite = await db.prepare("SELECT user_id, reset_id, reviewer FROM invites WHERE token_hash = ?")
    .bind(tokenHash).first<{ user_id: string | null; reset_id: string | null; reviewer: number }>();
  if (invite?.user_id && invite.reset_id) {
    return redeemReset(c.env, body, tokenHash, invite.user_id, invite.reset_id, k).then((r) => c.json(r, 201));
  }
  if (invite?.reviewer === 1) return c.json(await redeemReviewer(c.env, body, tokenHash, k), 201);

  const userId = newId();
  const deviceId = newId();
  const refreshToken = randomToken();
  const now = Date.now();

  // One transaction: claim the invite, then create the user and device only if the claim won.
  const [claim] = await db.batch([
    db.prepare(
      `UPDATE invites SET used_by = ?, used_at = ?
       WHERE token_hash = ? AND used_by IS NULL AND expires_at > ? AND user_id IS NULL AND reviewer = 0
         AND EXISTS (SELECT 1 FROM families f WHERE f.id = invites.family_id AND f.status = 'approved' AND f.hidden = 0)
         AND (created_by IS NOT NULL OR (
           NOT EXISTS (SELECT 1 FROM family_members m JOIN users u ON u.id = m.user_id
                       WHERE m.family_id = ${FAMILY_ONE} AND u.deleted_at IS NULL)
           AND NOT EXISTS (SELECT 1 FROM users WHERE operator = 1 AND deleted_at IS NULL)))`,
    ).bind(userId, now, tokenHash, now),
    db.prepare(
      `INSERT INTO users (id, name, is_admin, identity_pub, created_at)
       SELECT ?, name, make_admin, ?, ? FROM invites WHERE token_hash = ? AND used_by = ?`,
    ).bind(userId, identityPub, now, tokenHash, userId),
    // The invite's family; joining as admin carries no proof, like users.is_admin from an invite.
    db.prepare(
      `INSERT INTO family_members (family_id, user_id, role, joined_at)
       SELECT family_id, ?, CASE make_admin WHEN 1 THEN 'admin' ELSE 'member' END, ?
       FROM invites WHERE token_hash = ? AND used_by = ?`,
    ).bind(userId, now, tokenHash, userId),
    // A bootstrap invite (no creator) makes the operator and owns family #1.
    db.prepare(
      `UPDATE users SET operator = 1
       WHERE id = ? AND EXISTS (SELECT 1 FROM invites WHERE token_hash = ? AND used_by = ? AND created_by IS NULL)
         AND NOT EXISTS (SELECT 1 FROM users WHERE operator = 1 AND deleted_at IS NULL)`,
    ).bind(userId, tokenHash, userId),
    db.prepare(
      `UPDATE families SET created_by = ?
       WHERE id = ${FAMILY_ONE} AND created_by IS NULL
         AND EXISTS (SELECT 1 FROM invites WHERE token_hash = ? AND used_by = ? AND created_by IS NULL)`,
    ).bind(userId, tokenHash, userId),
    db.prepare(
      `INSERT INTO devices (id, user_id, name, platform, enc_pub, sign_pub, cert_sig, refresh_hash, created_at, last_seen)
       SELECT ?, id, ?, ?, ?, ?, ?, ?, ?, ? FROM users WHERE id = ?`,
    ).bind(deviceId, deviceName, platform, encPub, signPub, certSig, await sha256Hex(refreshToken), now, now, userId),
    eventStmt(db, { kind: "user_joined", userId, actorId: userId, payload: { deviceId }, at: now }, {
      sql: "EXISTS (SELECT 1 FROM invites WHERE token_hash = ? AND used_by = ?)",
      binds: [tokenHash, userId],
    }),
  ]);
  if (claim.meta.changes !== 1) return c.json(await retryRedeem(c.env, tokenHash, k, now), 201);
  await sharesChanged(c.env);

  const isAdmin =
    (await db.prepare("SELECT is_admin FROM users WHERE id = ?").bind(userId).first<number>("is_admin")) === 1;
  const accessToken = await signAccessToken(c.env, { sub: userId, dev: deviceId, adm: isAdmin });
  return c.json({ userId, deviceId, isAdmin, reviewer: false, accessToken, refreshToken }, 201);
});

/**
 * A reviewer invite (docs/protocol.md "Reviewer accounts") makes a new reviewer account each time
 * it is redeemed, named by the reviewer, until an admin revokes it. Nobody is told: the family
 * never sees reviewer accounts.
 */
async function redeemReviewer(env: Env, body: Record<string, unknown>, tokenHash: string, k: Keys) {
  const db = env.DB;
  const displayName = name(body.name, 40);
  const now = Date.now();
  // A retry whose 201 was lost: the same keys made a reviewer account just now.
  const prior = await db.prepare(
    `SELECT d.id AS device_id, u.id AS user_id FROM users u JOIN devices d ON d.user_id = u.id
       JOIN family_members m ON m.user_id = u.id AND m.family_id = ?
     WHERE u.deleted_at IS NULL AND u.identity_pub = ? AND u.created_at >= ?
       AND d.enc_pub = ? AND d.sign_pub = ? AND d.cert_sig = ? AND d.revoked_at IS NULL`,
  ).bind(REVIEWER_FAMILY, k.identityPub, now - REDEEM_RETRY_MS, k.encPub, k.signPub, k.certSig)
    .first<{ device_id: string; user_id: string }>();
  if (prior) return { ...(await reissue(env, prior.user_id, prior.device_id, false, now)), reviewer: true };

  const userId = newId();
  const deviceId = newId();
  const refreshToken = randomToken();
  const live = "EXISTS (SELECT 1 FROM invites WHERE token_hash = ? AND reviewer = 1 AND revoked_at IS NULL AND expires_at > ?)";
  const [user] = await db.batch([
    db.prepare(`INSERT INTO users (id, name, is_admin, identity_pub, created_at, reviewer) SELECT ?, ?, 0, ?, ?, 1 WHERE ${live}`)
      .bind(userId, displayName, k.identityPub, now, tokenHash, now),
    db.prepare(
      `INSERT INTO family_members (family_id, user_id, role, joined_at)
       SELECT family_id, ?, 'member', ? FROM invites WHERE token_hash = ? AND reviewer = 1 AND EXISTS (SELECT 1 FROM users WHERE id = ?)`,
    ).bind(userId, now, tokenHash, userId),
    db.prepare(
      `INSERT INTO devices (id, user_id, name, platform, enc_pub, sign_pub, cert_sig, refresh_hash, created_at, last_seen)
       SELECT ?, id, ?, ?, ?, ?, ?, ?, ?, ? FROM users WHERE id = ?`,
    ).bind(deviceId, k.deviceName, k.platform, k.encPub, k.signPub, k.certSig, await sha256Hex(refreshToken), now, now, userId),
    eventStmt(db, { kind: "user_joined", userId, actorId: userId, payload: { deviceId, reviewer: true }, at: now }, {
      sql: "EXISTS (SELECT 1 FROM users WHERE id = ?)",
      binds: [userId],
    }),
  ]);
  if (user.meta.changes !== 1) throw new ApiError("invite_invalid");
  await sharesChanged(env);
  const accessToken = await signAccessToken(env, { sub: userId, dev: deviceId, adm: false });
  return { userId, deviceId, isAdmin: false, reviewer: true, accessToken, refreshToken };
}

/** A client whose 201 was lost may retry with the same invite and the same keys. */
async function retryRedeem(env: Env, tokenHash: string, k: Keys, now: number) {
  const db = env.DB;
  const prior = await db.prepare(
    `SELECT d.id AS device_id, u.id AS user_id, u.is_admin
     FROM invites i JOIN users u ON u.id = i.used_by JOIN devices d ON d.user_id = u.id
     WHERE i.token_hash = ? AND i.used_at >= ? AND u.identity_pub = ?
       AND d.enc_pub = ? AND d.sign_pub = ? AND d.cert_sig = ? AND d.revoked_at IS NULL`,
  )
    .bind(tokenHash, now - REDEEM_RETRY_MS, k.identityPub, k.encPub, k.signPub, k.certSig)
    .first<{ device_id: string; user_id: string; is_admin: number }>();
  if (!prior) throw new ApiError("invite_invalid");
  return reissue(env, prior.user_id, prior.device_id, prior.is_admin === 1, now);
}

async function reissue(env: Env, userId: string, deviceId: string, isAdmin: boolean, now: number) {
  const refreshToken = randomToken();
  await env.DB.prepare("UPDATE devices SET refresh_hash = ?, prev_refresh_hash = NULL, last_seen = ? WHERE id = ?")
    .bind(await sha256Hex(refreshToken), now, deviceId)
    .run();
  const accessToken = await signAccessToken(env, { sub: userId, dev: deviceId, adm: isAdmin });
  return { userId, deviceId, isAdmin, reviewer: false, accessToken, refreshToken };
}

/**
 * A reset invite signs the existing user in with a new identity key. The new device proves it
 * holds the link's claim key (whose public half the admin signed) by signing its new identity key.
 */
async function redeemReset(env: Env, body: Record<string, unknown>, tokenHash: string, userId: string, resetId: string, k: Keys) {
  const db = env.DB;
  const claimSig = signature(body.resetClaimSig);
  const reset = await db.prepare("SELECT claim_pub FROM resets WHERE id = ? AND user_id = ?")
    .bind(resetId, userId).first<string>("claim_pub");
  if (!reset || !(await verifyEd25519(reset, claimSig, claimMessage(reset, k.identityPub)))) {
    throw new ApiError("invalid_request");
  }
  const deviceId = newId();
  const refreshToken = randomToken();
  const now = Date.now();
  const won = "EXISTS (SELECT 1 FROM invites WHERE token_hash = ? AND used_by = ? AND used_at = ?)";
  const wb = [tokenHash, userId, now];
  const [claim] = await db.batch([
    db.prepare(
      `UPDATE invites SET used_by = ?, used_at = ?
       WHERE token_hash = ? AND used_by IS NULL AND expires_at > ?`,
    ).bind(userId, now, tokenHash, now),
    // A recovery code registered under the old identity key stops working with it.
    db.prepare(`UPDATE users SET identity_pub = ?, recovery_pub = NULL, recovery_sig = NULL WHERE id = ? AND ${won}`)
      .bind(k.identityPub, userId, ...wb),
    db.prepare(
      `UPDATE resets SET new_identity_pub = ?, claim_sig = ?, completed_at = ? WHERE id = ? AND completed_at IS NULL AND ${won}`,
    ).bind(k.identityPub, claimSig, now, resetId, ...wb),
    db.prepare(
      `INSERT INTO devices (id, user_id, name, platform, enc_pub, sign_pub, cert_sig, refresh_hash, created_at, last_seen)
       SELECT ?, ?, ?, ?, ?, ?, ?, ?, ?, ? WHERE ${won}`,
    ).bind(deviceId, userId, k.deviceName, k.platform, k.encPub, k.signPub, k.certSig, await sha256Hex(refreshToken), now, now, ...wb),
    eventStmt(db, { kind: "reset_redeemed", userId, actorId: userId, payload: { resetId, deviceId }, at: now }, { sql: won, binds: wb }),
  ]);
  if (claim.meta.changes !== 1) return retryRedeem(env, tokenHash, k, now);

  const isAdmin = (await db.prepare("SELECT is_admin FROM users WHERE id = ?").bind(userId).first<number>("is_admin")) === 1;
  await notify(env, await sharingUserIds(db, userId), { type: "device", userId, deviceId });
  await notifyReset(env, userId, resetId);
  const accessToken = await signAccessToken(env, { sub: userId, dev: deviceId, adm: isAdmin });
  return { userId, deviceId, isAdmin, reviewer: false, accessToken, refreshToken };
}

/**
 * Step 1 of a recovery: whose recovery key this is, and their current identity key (both go into
 * the statement the recovering device signs). The public key is derived from the printed code and
 * isn't published anywhere while unused, so only the code's holder can ask.
 */
auth.post("/recover/lookup", async (c) => {
  const user = await recoveryUser(c.env.DB, pubKey((await readJson(c)).recoveryPub));
  return c.json({ userId: user.id, identityPub: user.identity_pub });
});

/**
 * The admin whose registered recovery key is [recoveryPub], if their current identity key signed
 * that registration (a key registered under an identity key since retired doesn't count).
 */
async function recoveryUser(db: D1Database, recoveryPub: string) {
  const user = await db.prepare(`SELECT id, identity_pub, recovery_sig FROM users
     WHERE recovery_pub = ?
       AND EXISTS (SELECT 1 FROM family_members m JOIN families f ON f.id = m.family_id
                   WHERE m.user_id = users.id AND m.role = 'admin' AND f.hidden = 0)`)
    .bind(recoveryPub).first<{ id: string; identity_pub: string; recovery_sig: string }>();
  if (!user || !(await verifyEd25519(user.identity_pub, user.recovery_sig, recoveryKeyMessage(user.id, recoveryPub)))) {
    throw new ApiError("unauthorized");
  }
  return user;
}

/**
 * Admin recovery without any device: the holder of the printed recovery code proves it with a
 * reset statement signed by the key derived from it, plus a claim over the new identity key.
 */
auth.post("/recover", async (c) => {
  assertConfigured(c.env);
  const db = c.env.DB;
  const body = await readJson(c);
  const now = Date.now();
  const k = await newDeviceKeys(body);
  const recoveryPub = pubKey(body.recoveryPub);
  const resetId = body.resetId;
  if (!isUlid(resetId)) throw new ApiError("invalid_request");
  const oldIdentityPub = pubKey(body.oldIdentityPub);
  const claimPub = pubKey(body.claimPub);
  const sig = signature(body.sig);
  const claimSig = signature(body.claimSig);

  // A retry of a recovery whose response was lost: same reset, same keys, within 10 minutes of
  // the recovery (checked before the signed time, which may be older by now).
  const done = await db.prepare(
    `SELECT r.user_id, d.id AS device_id, u.is_admin FROM resets r
     JOIN users u ON u.id = r.user_id
     JOIN devices d ON d.user_id = r.user_id AND d.enc_pub = ? AND d.sign_pub = ? AND d.cert_sig = ? AND d.revoked_at IS NULL
     WHERE r.id = ? AND r.signer_kind = 'recovery' AND r.signer_pub = ? AND r.new_identity_pub = ?
       AND u.identity_pub = ? AND r.completed_at >= ?`,
  ).bind(k.encPub, k.signPub, k.certSig, resetId, recoveryPub, k.identityPub, k.identityPub, now - REDEEM_RETRY_MS)
    .first<{ user_id: string; device_id: string; is_admin: number }>();
  if (done) return c.json(await reissue(c.env, done.user_id, done.device_id, done.is_admin === 1, now), 201);

  const createdAt = freshTime(body.createdAt, now);
  const user = await recoveryUser(db, recoveryPub);
  const statement = {
    resetId, userId: user.id, signerUserId: user.id, signerKind: "recovery" as const, oldIdentityPub, claimPub, createdAt,
  };
  if (!(await verifyEd25519(recoveryPub, sig, resetMessage(statement)))) throw new ApiError("invalid_request");
  if (!(await verifyEd25519(claimPub, claimSig, claimMessage(claimPub, k.identityPub)))) throw new ApiError("invalid_request");
  if (oldIdentityPub !== user.identity_pub) throw new ApiError("conflict");

  const deviceId = newId();
  const refreshToken = randomToken();
  const ok = await resetAccount(c.env, {
    statement,
    sig,
    signerPub: recoveryPub,
    recoverySig: user.recovery_sig,
    actorId: null,
    now,
    recovered: {
      recoveryPub,
      newIdentityPub: k.identityPub,
      claimSig,
      device: {
        id: deviceId, name: k.deviceName, platform: k.platform, encPub: k.encPub, signPub: k.signPub, certSig: k.certSig,
        refreshHash: await sha256Hex(refreshToken),
      },
    },
  });
  if (!ok) throw new ApiError("conflict");
  const accessToken = await signAccessToken(c.env, { sub: user.id, dev: deviceId, adm: true });
  return c.json({ userId: user.id, deviceId, isAdmin: true, accessToken, refreshToken }, 201);
});

auth.post("/refresh", async (c) => {
  assertConfigured(c.env);
  const oldHash = await sha256Hex(str((await readJson(c)).refreshToken));
  const next = randomToken();
  const nextHash = await sha256Hex(next);
  const now = Date.now();
  const db = c.env.DB;
  const RETURNING = "RETURNING id, user_id, (SELECT is_admin FROM users WHERE users.id = devices.user_id) AS is_admin";
  type Row = { id: string; user_id: string; is_admin: number };

  // 1. Normal rotation: the current token.
  let row = await db.prepare(
    `UPDATE devices SET prev_refresh_hash = refresh_hash, refresh_hash = ?, refreshed_at = ?, last_seen = ?
     WHERE refresh_hash = ? AND revoked_at IS NULL ${RETURNING}`,
  ).bind(nextHash, now, now, oldHash).first<Row>();

  // 2. The previous token inside the grace window (the last response was lost). The window is not extended.
  row ??= await db.prepare(
    `UPDATE devices SET refresh_hash = ?, last_seen = ?
     WHERE prev_refresh_hash = ? AND revoked_at IS NULL AND refreshed_at >= ? ${RETURNING}`,
  ).bind(nextHash, now, oldHash, now - REFRESH_GRACE_MS).first<Row>();

  if (!row) {
    // 3. The previous token after the window: treat as theft and revoke the device.
    await db.prepare(
      `UPDATE devices SET revoked_at = ?, refresh_hash = NULL, prev_refresh_hash = NULL, push_token = NULL
       WHERE prev_refresh_hash = ? AND revoked_at IS NULL`,
    ).bind(now, oldHash).run();
    throw new ApiError("unauthorized");
  }
  const accessToken = await signAccessToken(c.env, { sub: row.user_id, dev: row.id, adm: row.is_admin === 1 });
  return c.json({ accessToken, refreshToken: next });
});

