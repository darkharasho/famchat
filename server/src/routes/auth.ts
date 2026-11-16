import { Hono } from "hono";
import type { AppEnv, Env } from "../env";
import { verifyDeviceCert } from "../lib/devicecert";
import { ApiError } from "../lib/errors";
import { newId } from "../lib/ids";
import { randomToken, sha256Hex, signAccessToken } from "../lib/tokens";
import { name, readJson, str } from "../lib/validate";

export const PLATFORMS = ["ios", "android", "macos", "windows", "linux", "web"] as const;

export const auth = new Hono<AppEnv>();

export const REDEEM_RETRY_MS = 10 * 60 * 1000;
export const REFRESH_GRACE_MS = 60 * 1000;

function assertConfigured(env: Env): void {
  if (!env.TOKEN_SECRET) throw new ApiError("internal");
}

auth.post("/invite/redeem", async (c) => {
  assertConfigured(c.env);
  const body = await readJson(c);
  const token = str(body.token);
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

  const tokenHash = await sha256Hex(token);
  const userId = newId();
  const deviceId = newId();
  const refreshToken = randomToken();
  const now = Date.now();
  const db = c.env.DB;

  // One transaction: claim the invite, then create the user and device only if the claim won.
  const [claim] = await db.batch([
    db.prepare(
      `UPDATE invites SET used_by = ?, used_at = ?
       WHERE token_hash = ? AND used_by IS NULL AND expires_at > ?
         AND (created_by IS NOT NULL OR NOT EXISTS (SELECT 1 FROM users))`,
    ).bind(userId, now, tokenHash, now),
    db.prepare(
      `INSERT INTO users (id, name, is_admin, identity_pub, created_at)
       SELECT ?, name, make_admin, ?, ? FROM invites WHERE token_hash = ? AND used_by = ?`,
    ).bind(userId, identityPub, now, tokenHash, userId),
    db.prepare(
      `INSERT INTO devices (id, user_id, name, platform, enc_pub, sign_pub, cert_sig, refresh_hash, created_at, last_seen)
       SELECT ?, id, ?, ?, ?, ?, ?, ?, ?, ? FROM users WHERE id = ?`,
    ).bind(deviceId, deviceName, platform, encPub, signPub, certSig, await sha256Hex(refreshToken), now, now, userId),
  ]);
  if (claim.meta.changes !== 1) {
    // A client whose 201 was lost may retry with the same invite and the same keys.
    const prior = await db.prepare(
      `SELECT d.id AS device_id, u.id AS user_id, u.is_admin
       FROM invites i JOIN users u ON u.id = i.used_by JOIN devices d ON d.user_id = u.id
       WHERE i.token_hash = ? AND i.used_at >= ? AND u.identity_pub = ?
         AND d.enc_pub = ? AND d.sign_pub = ? AND d.cert_sig = ? AND d.revoked_at IS NULL`,
    )
      .bind(tokenHash, now - REDEEM_RETRY_MS, identityPub, encPub, signPub, certSig)
      .first<{ device_id: string; user_id: string; is_admin: number }>();
    if (!prior) throw new ApiError("invite_invalid");
    await db.prepare("UPDATE devices SET refresh_hash = ?, last_seen = ? WHERE id = ?")
      .bind(await sha256Hex(refreshToken), now, prior.device_id)
      .run();
    const adm = prior.is_admin === 1;
    const accessToken = await signAccessToken(c.env, { sub: prior.user_id, dev: prior.device_id, adm });
    return c.json(
      { userId: prior.user_id, deviceId: prior.device_id, isAdmin: adm, accessToken, refreshToken },
      201,
    );
  }

  const isAdmin =
    (await db.prepare("SELECT is_admin FROM users WHERE id = ?").bind(userId).first<number>("is_admin")) === 1;
  const accessToken = await signAccessToken(c.env, { sub: userId, dev: deviceId, adm: isAdmin });
  return c.json({ userId, deviceId, isAdmin, accessToken, refreshToken }, 201);
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
