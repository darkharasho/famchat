// QR pairing: an existing device approves a new device of the same user.
//
// 1. The new device (no account yet) starts a session with an ephemeral X25519 key, its device keys
//    and a MAC over them keyed by a secret it never sends here; it shows a code and a QR.
// 2. A signed-in device of the user looks the session up by the code, checks the MAC with the
//    secret it got from the code/QR, signs the new device's certificate and posts an encrypted
//    bundle (identity key and chat keys) that only the new device can open.
// 3. The new device claims the session with its claim secret: its device row is created and it gets
//    tokens and the bundle. Member devices are told so they add wraps for it.
//
// Reverse direction (a signed-in device without a camera, a new phone): the signed-in device opens an
// "offer" and shows its code and a QR; the new device scans it and starts its session with the offer's
// code, which binds the session to the offering user. The offering device polls the offer, then checks
// the MAC and approves exactly as above.
//
// The server never sees the bundle's key, so it can't read or forge it (docs/protocol.md "Pairing").
import { Hono } from "hono";
import type { AppEnv } from "../env";
import { verifyDeviceCert } from "../lib/devicecert";
import { b64urlDecode } from "../lib/encoding";
import { ApiError } from "../lib/errors";
import { sharingUserIds } from "../lib/family";
import { logEvent } from "../lib/reset";
import { newId } from "../lib/ids";
import { randomToken, sha256Hex, signAccessToken } from "../lib/tokens";
import { name, readJson, str } from "../lib/validate";
import { requireAuth } from "../middleware/auth";
import { notify } from "../notify";
import { PLATFORMS } from "./auth";

/** A started session can be approved for this long. */
export const PAIR_TTL_MS = 5 * 60 * 1000;
/** After approval the new device has this long to claim; after a claim, this long to claim again (lost response). */
export const CLAIM_RETRY_MS = 10 * 60 * 1000;
/** Sessions older than this are deleted. */
const KEEP_MS = 60 * 60 * 1000;
export const MAX_PER_IP = 5;
const IP_WINDOW_MS = 10 * 60 * 1000;
/** A storage guard only; the per-network limit is what stops abuse. */
export const MAX_LIVE = 1000;
/** Offers one user may open per [IP_WINDOW_MS]. */
export const MAX_OFFERS_PER_USER = 5;

/**
 * The rate-limit key for a client address: an IPv6 address by its /64 (one subscriber usually has a
 * whole /64), an IPv4 address as is.
 */
export function ipKey(ip: string | null): string | null {
  if (!ip) return null;
  if (!ip.includes(":")) return ip;
  const [head, tail = ""] = ip.toLowerCase().split("::");
  const h = head ? head.split(":") : [];
  const t = tail ? tail.split(":") : [];
  const groups = ip.includes("::") ? [...h, ...Array(Math.max(0, 8 - h.length - t.length)).fill("0"), ...t] : h;
  return groups.slice(0, 4).map((g) => g.replace(/^0+(?=.)/, "")).join(":") + "::/64";
}
export const MAX_BUNDLE_BYTES = 256 * 1024;

const CODE_ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
const CODE = /^[0-9A-HJKMNP-TV-Z]{4}$/;

function newCode(): string {
  let s = "";
  for (const b of crypto.getRandomValues(new Uint8Array(4))) s += CODE_ALPHABET[b % 32];
  return s;
}

/** base64url of exactly [len] bytes, else invalid_request. */
function key(v: unknown, len: number): string {
  const s = str(v);
  if (b64urlDecode(s).length !== len) throw new ApiError("invalid_request");
  return s;
}

type Session = {
  id: string;
  code: string;
  secret_hash: string;
  device_id: string;
  eph_pub: string;
  enc_pub: string;
  sign_pub: string;
  keys_mac: string;
  device_name: string;
  platform: string;
  expires_at: number;
  user_id: string | null;
  approved_at: number | null;
  approved_by_device: string | null;
  cert_sig: string | null;
  bundle: string | null;
  claimed_at: number | null;
  cancelled_at: number | null;
  offer_user_id: string | null;
};

type Offer = {
  id: string;
  code: string;
  user_id: string;
  device_id: string;
  created_at: number;
  expires_at: number;
  session_id: string | null;
  cancelled_at: number | null;
};

/** A session as an approving device sees it. */
function sessionOut(s: Session) {
  return {
    code: s.code,
    deviceId: s.device_id,
    ephPub: s.eph_pub,
    encPub: s.enc_pub,
    signPub: s.sign_pub,
    keysMac: s.keys_mac,
    deviceName: s.device_name,
    platform: s.platform,
    expiresAt: s.expires_at,
  };
}

export const pairing = new Hono<AppEnv>();

pairing.post("/start", async (c) => {
  const body = await readJson(c);
  const ephPub = key(body.ephPub, 32);
  const encPub = key(body.encPub, 32);
  const signPub = key(body.signPub, 32);
  const keysMac = key(body.keysMac, 32);
  const deviceName = name(body.deviceName, 60);
  const platform = str(body.platform);
  if (!(PLATFORMS as readonly string[]).includes(platform)) throw new ApiError("invalid_request");
  // Reverse pairing: the code of the offer the new device scanned or typed.
  const offerCode = body.offer === undefined ? null : str(body.offer).toUpperCase();
  if (offerCode !== null && !CODE.test(offerCode)) throw new ApiError("invalid_request");

  const db = c.env.DB;
  const now = Date.now();
  const ip = ipKey(c.req.header("cf-connecting-ip") ?? null);
  const [, perIp, live] = await db.batch([
    db.prepare("DELETE FROM pair_sessions WHERE created_at < ?").bind(now - KEEP_MS),
    db.prepare("SELECT COUNT(*) AS n FROM pair_sessions WHERE client_ip = ? AND created_at > ?").bind(ip, now - IP_WINDOW_MS),
    db.prepare(
      "SELECT COUNT(*) AS n FROM pair_sessions WHERE expires_at > ? AND approved_at IS NULL AND cancelled_at IS NULL",
    ).bind(now),
  ]);
  const count = (r: D1Result) => (r.results[0] as { n: number }).n;
  if (count(perIp) >= MAX_PER_IP || count(live) >= MAX_LIVE) throw new ApiError("rate_limited");

  const id = newId(now);
  const deviceId = newId(now);
  const secret = randomToken();
  const expiresAt = now + PAIR_TTL_MS;
  for (let attempt = 0; ; attempt++) {
    const code = newCode();
    // With an offer the session is born cancelled and comes alive only if it takes the offer, in the
    // same transaction. A failed try still counts against the network's start limit (offer guessing).
    const insert = db.prepare(
      `INSERT INTO pair_sessions (id, code, secret_hash, device_id, eph_pub, enc_pub, sign_pub, keys_mac,
         device_name, platform, client_ip, created_at, expires_at, cancelled_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    ).bind(id, code, await sha256Hex(secret), deviceId, ephPub, encPub, signPub, keysMac, deviceName, platform, ip, now, expiresAt,
      offerCode === null ? null : now);
    try {
      if (offerCode === null) {
        await insert.run();
      } else {
        const [, , taken] = await db.batch([
          insert,
          db.prepare(
            `UPDATE pair_offers SET session_id = ?
             WHERE code = ? AND session_id IS NULL AND cancelled_at IS NULL AND expires_at > ?`,
          ).bind(id, offerCode, now),
          db.prepare(
            `UPDATE pair_sessions SET cancelled_at = NULL,
               offer_user_id = (SELECT user_id FROM pair_offers WHERE session_id = ?)
             WHERE id = ? AND EXISTS (SELECT 1 FROM pair_offers WHERE session_id = ?)`,
          ).bind(id, id, id),
        ]);
        if (taken.meta.changes !== 1) throw new ApiError("not_found");
      }
      return c.json({ sessionId: id, code, secret, deviceId, expiresAt, expiresIn: PAIR_TTL_MS }, 201);
    } catch (e) {
      // A code still held by a recent session: pick another.
      if (attempt >= 5 || !String(e).includes("UNIQUE")) throw e;
    }
  }
});

/**
 * A pending session by its code, for an approving device of [userId]. Unknown, expired, cancelled,
 * used, or started from another user's offer → 404.
 */
async function pending(db: D1Database, code: string, userId: string, now: number): Promise<Session> {
  const c = code.toUpperCase();
  if (!CODE.test(c)) throw new ApiError("not_found");
  const s = await db.prepare(
    `SELECT * FROM pair_sessions WHERE code = ? AND approved_at IS NULL AND cancelled_at IS NULL AND expires_at > ?
       AND (offer_user_id IS NULL OR offer_user_id = ?)`,
  ).bind(c, now, userId).first<Session>();
  if (!s) throw new ApiError("not_found");
  return s;
}

// --- reverse pairing: the signed-in device's offer ---

pairing.post("/offer", requireAuth, async (c) => {
  const db = c.env.DB;
  const now = Date.now();
  const userId = c.get("userId");
  const [, recent] = await db.batch([
    db.prepare("DELETE FROM pair_offers WHERE created_at < ?").bind(now - KEEP_MS),
    db.prepare("SELECT COUNT(*) AS n FROM pair_offers WHERE user_id = ? AND created_at > ?").bind(userId, now - IP_WINDOW_MS),
  ]);
  if ((recent.results[0] as { n: number }).n >= MAX_OFFERS_PER_USER) throw new ApiError("rate_limited");
  const id = newId(now);
  const expiresAt = now + PAIR_TTL_MS;
  for (let attempt = 0; ; attempt++) {
    const code = newCode();
    try {
      await db.prepare(
        "INSERT INTO pair_offers (id, code, user_id, device_id, created_at, expires_at) VALUES (?, ?, ?, ?, ?, ?)",
      ).bind(id, code, userId, c.get("deviceId"), now, expiresAt).run();
      return c.json({ offerId: id, code, expiresAt, expiresIn: PAIR_TTL_MS }, 201);
    } catch (e) {
      if (attempt >= 5 || !String(e).includes("UNIQUE")) throw e;
    }
  }
});

/** The caller's own offer by id; another user's or an unknown one → 404. */
async function ownOffer(db: D1Database, id: string, userId: string): Promise<Offer> {
  const o = await db.prepare("SELECT * FROM pair_offers WHERE id = ? AND user_id = ?").bind(id, userId).first<Offer>();
  if (!o) throw new ApiError("not_found");
  return o;
}

/**
 * The offering device polls: `waiting` until a new device takes the offer, then `ready` with its
 * session (to check and approve as with a scanned code), then `approved`. Gone → 410.
 */
pairing.get("/offer/:id", requireAuth, async (c) => {
  const db = c.env.DB;
  const now = Date.now();
  const o = await ownOffer(db, c.req.param("id"), c.get("userId"));
  if (o.cancelled_at !== null) throw new ApiError("pairing_invalid");
  if (o.session_id === null) {
    if (o.expires_at <= now) throw new ApiError("pairing_invalid");
    return c.json({ status: "waiting", expiresAt: o.expires_at });
  }
  const s = await db.prepare("SELECT * FROM pair_sessions WHERE id = ?").bind(o.session_id).first<Session>();
  if (!s || s.cancelled_at !== null) throw new ApiError("pairing_invalid");
  if (s.approved_at !== null) return c.json({ status: "approved" });
  if (s.expires_at <= now) throw new ApiError("pairing_invalid");
  return c.json({ status: "ready", session: sessionOut(s) });
});

/** Withdraws the offer, and the new device's session if it took the offer and isn't approved yet. */
pairing.post("/offer/:id/cancel", requireAuth, async (c) => {
  const db = c.env.DB;
  const now = Date.now();
  const o = await ownOffer(db, c.req.param("id"), c.get("userId"));
  await db.batch([
    db.prepare("UPDATE pair_offers SET cancelled_at = ? WHERE id = ? AND cancelled_at IS NULL").bind(now, o.id),
    db.prepare(
      `UPDATE pair_sessions SET cancelled_at = ?
       WHERE id = (SELECT session_id FROM pair_offers WHERE id = ?) AND approved_at IS NULL AND cancelled_at IS NULL`,
    ).bind(now, o.id),
  ]);
  return c.body(null, 204);
});

pairing.get("/:code", requireAuth, async (c) => {
  const s = await pending(c.env.DB, c.req.param("code"), c.get("userId"), Date.now());
  return c.json({ session: sessionOut(s) });
});

/** The new device's certificate, signed by the caller's identity key, and the sealed bundle. */
pairing.post("/:code/approve", requireAuth, async (c) => {
  const db = c.env.DB;
  const now = Date.now();
  const userId = c.get("userId");
  const s = await pending(db, c.req.param("code"), userId, now);
  const body = await readJson(c);
  if (body.deviceId !== s.device_id) throw new ApiError("invalid_request");
  const certSig = key(body.certSig, 64);
  const bundle = str(body.bundle);
  const size = b64urlDecode(bundle).length;
  if (size < 32 + 24 + 16 || size > MAX_BUNDLE_BYTES) throw new ApiError("invalid_request");
  const identityPub = await db.prepare("SELECT identity_pub FROM users WHERE id = ?").bind(userId).first<string>("identity_pub");
  if (!identityPub || !(await verifyDeviceCert(identityPub, s.enc_pub, s.sign_pub, certSig))) {
    throw new ApiError("invalid_request");
  }
  const res = await db.prepare(
    `UPDATE pair_sessions SET user_id = ?, approved_by_device = ?, approved_at = ?, cert_sig = ?, bundle = ?
     WHERE id = ? AND approved_at IS NULL AND cancelled_at IS NULL AND expires_at > ?`,
  ).bind(userId, c.get("deviceId"), now, certSig, bundle, s.id, now).run();
  if (res.meta.changes !== 1) throw new ApiError("not_found");
  return c.body(null, 204);
});

/** The new device's session by id and claim secret; wrong secret looks like an unknown session. */
async function owned(db: D1Database, body: Record<string, unknown>): Promise<Session> {
  const id = str(body.sessionId);
  const secretHash = await sha256Hex(str(body.secret));
  const s = await db.prepare("SELECT * FROM pair_sessions WHERE id = ?").bind(id).first<Session>();
  if (!s || s.secret_hash !== secretHash) throw new ApiError("not_found");
  return s;
}

pairing.post("/claim", async (c) => {
  const db = c.env.DB;
  const now = Date.now();
  const s = await owned(db, await readJson(c));
  if (s.cancelled_at !== null) throw new ApiError("pairing_invalid");
  if (s.approved_at === null) {
    if (s.expires_at <= now) throw new ApiError("pairing_invalid");
    return c.json({ status: "waiting" });
  }
  const userId = s.user_id!;
  const refreshToken = randomToken();
  const refreshHash = await sha256Hex(refreshToken);
  let created = false;
  if (s.claimed_at === null) {
    if (s.approved_at + CLAIM_RETRY_MS <= now) throw new ApiError("pairing_invalid");
    // The approving device must still be live: a revoked (maybe stolen) device can't add devices.
    const approver = await db.prepare("SELECT 1 FROM devices WHERE id = ? AND revoked_at IS NULL")
      .bind(s.approved_by_device).first();
    if (!approver) throw new ApiError("pairing_invalid");
    // The user's identity key may have changed since the approval (an admin reset).
    const identityPub = await db.prepare("SELECT identity_pub FROM users WHERE id = ?").bind(userId).first<string>("identity_pub");
    if (!identityPub || !(await verifyDeviceCert(identityPub, s.enc_pub, s.sign_pub, s.cert_sig!))) {
      throw new ApiError("pairing_invalid");
    }
    try {
      const [claimed] = await db.batch([
        db.prepare("UPDATE pair_sessions SET claimed_at = ? WHERE id = ? AND claimed_at IS NULL").bind(now, s.id),
        db.prepare(
          `INSERT INTO devices (id, user_id, name, platform, enc_pub, sign_pub, cert_sig, refresh_hash, created_at, last_seen)
           SELECT device_id, user_id, device_name, platform, enc_pub, sign_pub, cert_sig, ?, ?, ?
           FROM pair_sessions WHERE id = ? AND claimed_at = ?`,
        ).bind(refreshHash, now, now, s.id, now),
      ]);
      created = claimed.meta.changes === 1;
    } catch (e) {
      // A concurrent claim of the same session won; fall through to the repeat path.
      if (!String(e).includes("UNIQUE")) throw e;
    }
  }
  if (!created) {
    // A repeat claim (the previous response was lost): new tokens for the same device.
    const claimedAt = s.claimed_at ?? now;
    if (claimedAt + CLAIM_RETRY_MS <= now) throw new ApiError("pairing_invalid");
    const res = await db.prepare(
      `UPDATE devices SET refresh_hash = ?, prev_refresh_hash = NULL, last_seen = ? WHERE id = ? AND revoked_at IS NULL`,
    ).bind(refreshHash, now, s.device_id).run();
    if (res.meta.changes !== 1) throw new ApiError("pairing_invalid");
  }
  const isAdmin = (await db.prepare("SELECT is_admin FROM users WHERE id = ?").bind(userId).first<number>("is_admin")) === 1;
  const accessToken = await signAccessToken(c.env, { sub: userId, dev: s.device_id, adm: isAdmin });
  if (created) {
    await logEvent(db, {
      kind: "device_paired", userId, actorId: userId, payload: { deviceId: s.device_id, approvedBy: s.approved_by_device }, at: now,
    });
    await notify(c.env, await sharingUserIds(db, userId), { type: "device", userId, deviceId: s.device_id });
  }
  return c.json({
    status: "approved",
    userId,
    deviceId: s.device_id,
    isAdmin,
    accessToken,
    refreshToken,
    bundle: s.bundle,
  });
});

pairing.post("/cancel", async (c) => {
  const db = c.env.DB;
  const s = await owned(db, await readJson(c));
  await db.prepare("UPDATE pair_sessions SET cancelled_at = ? WHERE id = ? AND claimed_at IS NULL AND cancelled_at IS NULL")
    .bind(Date.now(), s.id).run();
  return c.body(null, 204);
});
