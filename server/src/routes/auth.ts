import { Hono } from "hono";
import type { AppEnv } from "../env";
import { verifyDeviceCert } from "../lib/devicecert";
import { ApiError } from "../lib/errors";
import { newId } from "../lib/ids";
import { randomToken, sha256Hex, signAccessToken } from "../lib/tokens";
import { name, readJson, str } from "../lib/validate";

export const PLATFORMS = ["ios", "android", "macos", "windows", "linux", "web"] as const;

export const auth = new Hono<AppEnv>();

auth.post("/invite/redeem", async (c) => {
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
      "UPDATE invites SET used_by = ?, used_at = ? WHERE token_hash = ? AND used_by IS NULL AND expires_at > ?",
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
  if (claim.meta.changes !== 1) throw new ApiError("invite_invalid");

  const isAdmin =
    (await db.prepare("SELECT is_admin FROM users WHERE id = ?").bind(userId).first<number>("is_admin")) === 1;
  const accessToken = await signAccessToken(c.env, { sub: userId, dev: deviceId, adm: isAdmin });
  return c.json({ userId, deviceId, isAdmin, accessToken, refreshToken }, 201);
});
