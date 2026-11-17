import { Hono } from "hono";
import type { AppEnv } from "../env";
import { type ResetRow, resetOut } from "../lib/reset";
import { ApiError } from "../lib/errors";
import { requireAuth } from "../middleware/auth";
import { avatarObject } from "./me";

export const users = new Hono<AppEnv>();
users.use(requireAuth);

/**
 * The family directory: every user with every device's public keys and certificate, so clients can
 * check that a device's keys chain to its user's identity key. Revoked devices stay listed (marked),
 * because their signatures on old messages must still verify.
 */
users.get("/", async (c) => {
  const db = c.env.DB;
  // Reviewer accounts and the family never see each other (docs/protocol.md "Reviewer accounts").
  const side = c.get("reviewer") ? 1 : 0;
  const mine = "SELECT id FROM users WHERE reviewer = ?";
  const [u, d, r] = await db.batch([
    db.prepare(
      "SELECT id, name, is_admin, identity_pub, admin_by, admin_signer_pub, admin_sig, deleted_at, avatar_key FROM users WHERE reviewer = ? ORDER BY created_at",
    ).bind(side),
    db.prepare(
      `SELECT id, user_id, name, platform, enc_pub, sign_pub, cert_sig, revoked_at FROM devices
       WHERE user_id IN (${mine}) ORDER BY created_at`,
    ).bind(side),
    db.prepare(`SELECT * FROM resets WHERE user_id IN (${mine}) ORDER BY created_at, id`).bind(side),
  ]);
  // Each user's signed resets: their identity key history, which clients verify themselves.
  const resets = new Map<string, object[]>();
  for (const x of r.results as ResetRow[]) {
    const list = resets.get(x.user_id) ?? [];
    list.push(resetOut(x));
    resets.set(x.user_id, list);
  }
  type D = { id: string; user_id: string; name: string; platform: string; enc_pub: string; sign_pub: string; cert_sig: string; revoked_at: number | null };
  const byUser = new Map<string, object[]>();
  for (const x of d.results as D[]) {
    const list = byUser.get(x.user_id) ?? [];
    list.push({
      id: x.id,
      name: x.name,
      platform: x.platform,
      encPub: x.enc_pub,
      signPub: x.sign_pub,
      certSig: x.cert_sig,
      revoked: x.revoked_at !== null,
    });
    byUser.set(x.user_id, list);
  }
  type U = {
    id: string; name: string; is_admin: number; identity_pub: string;
    admin_by: string | null; admin_signer_pub: string | null; admin_sig: string | null; deleted_at: number | null;
    avatar_key: string | null;
  };
  return c.json({
    users: (u.results as U[]).map((x) => ({
      id: x.id,
      name: x.name,
      isAdmin: x.is_admin === 1,
      identityPub: x.identity_pub,
      // Who made this user an admin, signed (null for the first admin, who was bootstrapped).
      adminProof: x.admin_sig ? { byUserId: x.admin_by, signerPub: x.admin_signer_pub, sig: x.admin_sig } : null,
      devices: byUser.get(x.id) ?? [],
      resets: resets.get(x.id) ?? [],
      // A deleted account stays listed (its devices' certificates and resets still verify), named
      // "Deleted user" with every device revoked. Clients don't offer it for new chats.
      deleted: x.deleted_at !== null,
      // Their profile photo (GET /users/:id/avatar?v=<avatarKey>), or null.
      avatarKey: x.avatar_key,
    })),
  });
});

/**
 * A user's profile photo (JPEG). With `?v=<avatarKey>` it's that photo, cacheable for good (a new
 * photo gets a new key); 404 once it's been replaced. Only users on the same side of the reviewer
 * line see each other's.
 */
users.get("/:id/avatar", async (c) => {
  const row = await c.env.DB.prepare(
    "SELECT avatar_key FROM users WHERE id = ? AND reviewer = ? AND deleted_at IS NULL",
  ).bind(c.req.param("id"), c.get("reviewer") ? 1 : 0).first<{ avatar_key: string | null }>();
  const key = row?.avatar_key;
  const v = c.req.query("v");
  if (!key || (v !== undefined && v !== key)) throw new ApiError("not_found");
  const obj = await c.env.MEDIA.get(avatarObject(c.req.param("id"), key));
  if (!obj) throw new ApiError("not_found");
  return new Response(obj.body, {
    headers: {
      "content-type": "image/jpeg",
      "content-length": String(obj.size),
      "cache-control": v ? "private, max-age=31536000, immutable" : "private, no-cache",
    },
  });
});
