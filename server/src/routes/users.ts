import { Hono } from "hono";
import type { AppEnv } from "../env";
import { type ResetRow, resetOut } from "../lib/reset";
import { DIRECTORY_PEERS_SQL, FAMILY_ONE } from "../lib/family";
import { ApiError } from "../lib/errors";
import { requireAuth } from "../middleware/auth";
import { avatarObject } from "./me";

export const users = new Hono<AppEnv>();
users.use(requireAuth);

/** Binds the user id twice: people who share a chat with them (or left one of their chats) but no family. */
const FORMER_SQL = `SELECT user_id FROM chat_members
    WHERE chat_id IN (SELECT chat_id FROM chat_members WHERE user_id = ?)
  UNION SELECT user_id FROM chat_leavers
    WHERE chat_id IN (SELECT chat_id FROM chat_members WHERE user_id = ?)
  EXCEPT ${DIRECTORY_PEERS_SQL}`;

/** `id` filter for everyone the caller may see: themselves, family peers and former chat partners. Binds the user id 5 times. */
const VISIBLE_SQL = `(id = ? OR id IN (${DIRECTORY_PEERS_SQL}) OR id IN (${FORMER_SQL}))`;

type Proof = { byUserId: string | null; signerPub: string | null; sig: string };

/**
 * The directory: the caller, everyone who shares a family with them, and "former" chat partners
 * (people they share a chat with but no family any more, listed so history still verifies). Each
 * entry has every device's public keys and certificate, so clients can check that a device's keys
 * chain to its user's identity key. Revoked devices stay listed (marked), because their signatures
 * on old messages must still verify. Nobody else is ever listed (docs/protocol.md "Directory").
 */
users.get("/", async (c) => {
  const db = c.env.DB;
  const me = c.get("userId");
  const vb = [me, me, me, me, me];
  const [m, u, d, r] = await db.batch([
    // Members of every family the caller is in; everyone in these rows is a family peer.
    db.prepare(
      `SELECT family_id, user_id, role, admin_by, admin_signer_pub, admin_sig FROM family_members
       WHERE family_id IN (SELECT family_id FROM family_members WHERE user_id = ?)`,
    ).bind(me),
    db.prepare(
      `SELECT id, name, identity_pub, deleted_at, avatar_key FROM users WHERE ${VISIBLE_SQL} ORDER BY created_at`,
    ).bind(...vb),
    db.prepare(
      `SELECT id, user_id, name, platform, enc_pub, sign_pub, cert_sig, revoked_at FROM devices
       WHERE user_id IN (SELECT id FROM users WHERE ${VISIBLE_SQL}) ORDER BY created_at`,
    ).bind(...vb),
    db.prepare(
      `SELECT * FROM resets WHERE user_id IN (SELECT id FROM users WHERE ${VISIBLE_SQL}) ORDER BY created_at, id`,
    ).bind(...vb),
  ]);
  type M = {
    family_id: number; user_id: string; role: "admin" | "member";
    admin_by: string | null; admin_signer_pub: string | null; admin_sig: string | null;
  };
  const memberRows = m.results as M[];
  const proofOf = (x: M): Proof | null =>
    x.role === "admin" && x.admin_sig ? { byUserId: x.admin_by, signerPub: x.admin_signer_pub, sig: x.admin_sig } : null;
  const callerInOne = memberRows.some((x) => x.user_id === me && x.family_id === FAMILY_ONE);
  const familiesBy = new Map<string, { id: number; role: string; adminProof: Proof | null }[]>();
  const familyOne = new Map<string, M>();
  for (const x of memberRows) {
    const list = familiesBy.get(x.user_id) ?? [];
    list.push({ id: x.family_id, role: x.role, adminProof: proofOf(x) });
    familiesBy.set(x.user_id, list);
    if (x.family_id === FAMILY_ONE) familyOne.set(x.user_id, x);
  }
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
  type U = { id: string; name: string; identity_pub: string; deleted_at: number | null; avatar_key: string | null };
  return c.json({
    users: (u.results as U[]).map((x) => {
      // Rows from family_members are family peers; anyone else listed is a former chat partner.
      const families = familiesBy.get(x.id) ?? [];
      // isAdmin/adminProof describe family #1, and only to people in it (they never leak its roles).
      const one = callerInOne ? familyOne.get(x.id) : undefined;
      return {
        id: x.id,
        name: x.name,
        isAdmin: one?.role === "admin",
        identityPub: x.identity_pub,
        // Who made this user an admin, signed (null for the first admin, who was bootstrapped).
        adminProof: one ? proofOf(one) : null,
        devices: byUser.get(x.id) ?? [],
        resets: resets.get(x.id) ?? [],
        // A deleted account stays listed (its devices' certificates and resets still verify), named
        // "Deleted user" with every device revoked. Clients don't offer it for new chats.
        deleted: x.deleted_at !== null,
        // Their profile photo (GET /users/:id/avatar?v=<avatarKey>), or null.
        avatarKey: x.avatar_key,
        // Only the families shared with the caller.
        families,
        former: families.length === 0 && x.id !== me,
      };
    }),
  });
});

/**
 * A user's profile photo (JPEG). With `?v=<avatarKey>` it's that photo, cacheable for good (a new
 * photo gets a new key); 404 once it's been replaced. Only people in the caller's directory
 * (themselves, family peers, former chat partners) can be fetched.
 */
users.get("/:id/avatar", async (c) => {
  const me = c.get("userId");
  const row = await c.env.DB.prepare(
    `SELECT avatar_key FROM users WHERE id = ? AND deleted_at IS NULL AND ${VISIBLE_SQL}`,
  ).bind(c.req.param("id"), me, me, me, me, me).first<{ avatar_key: string | null }>();
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
