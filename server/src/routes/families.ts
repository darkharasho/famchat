import { Hono, type MiddlewareHandler } from "hono";
import type { AppEnv } from "../env";
import { ApiError } from "../lib/errors";
import { FAMILY_ONE, familyRole, getFamily, notifyFamily, requireFamilyAdmin, sharesChanged } from "../lib/family";
import { eventStmt, logEvent, promotionMessageV2, signature, verifyEd25519 } from "../lib/reset";
import { sha256Hex } from "../lib/tokens";
import { name, readJson } from "../lib/validate";
import { requireAuth } from "../middleware/auth";
import { createInvite } from "./admin";

export const families = new Hono<AppEnv>();

/** Reviewers live in the hidden family and never see the family endpoints. */
const rejectReviewers: MiddlewareHandler<AppEnv> = async (c, next) => {
  if (c.get("reviewer")) throw new ApiError("forbidden");
  await next();
};
families.use(requireAuth, rejectReviewers);

const MAX_PENDING = 3;

interface FamilyRow {
  id: number;
  name: string;
  status: string;
  role: string;
  member_count: number;
  created_by: string | null;
  created_at: number;
}

const familyOut = (r: FamilyRow, userId: string) => ({
  id: r.id,
  name: r.name,
  status: r.status,
  role: r.role,
  memberCount: r.member_count,
  owner: r.created_by === userId,
  createdAt: r.created_at,
});

const FAMILY_SELECT = `SELECT f.id, f.name, f.status, f.created_by, f.created_at, m.role,
  (SELECT COUNT(*) FROM family_members x JOIN users u ON u.id = x.user_id AND u.deleted_at IS NULL
   WHERE x.family_id = f.id) AS member_count
  FROM families f JOIN family_members m ON m.family_id = f.id AND m.user_id = ?`;

/** The caller's non-hidden families, with their role, ownership and live member count. */
families.get("/", async (c) => {
  const userId = c.get("userId");
  const { results } = await c.env.DB.prepare(`${FAMILY_SELECT} WHERE f.hidden = 0 ORDER BY f.id`)
    .bind(userId).all<FamilyRow>();
  return c.json({ families: results.map((r) => familyOut(r, userId)) });
});

/** Requests a new family: pending until the operator approves it. The caller becomes its (unproven) admin. */
families.post("/", async (c) => {
  const db = c.env.DB;
  const userId = c.get("userId");
  const famName = name((await readJson(c)).name, 40);
  const pending = await db.prepare("SELECT COUNT(*) AS n FROM families WHERE created_by = ? AND status = 'pending'")
    .bind(userId).first<number>("n");
  if ((pending ?? 0) >= MAX_PENDING) throw new ApiError("rate_limited");
  const now = Date.now();
  const res = await db.prepare(
    "INSERT INTO families (name, created_by, status, hidden, created_at) VALUES (?, ?, 'pending', 0, ?)",
  ).bind(famName, userId, now).run();
  const id = res.meta.last_row_id as number;
  await db.prepare("INSERT INTO family_members (family_id, user_id, role, joined_at) VALUES (?, ?, 'admin', ?)")
    .bind(id, userId, now).run();
  await logEvent(db, { kind: "family_requested", userId, actorId: userId, payload: { familyId: id, name: famName } });
  const row = await db.prepare(`${FAMILY_SELECT} WHERE f.id = ?`).bind(userId, id).first<FamilyRow>();
  return c.json({ family: familyOut(row!, userId) }, 201);
});

/** Renames a family: its admin if approved, or its creator while it is still pending (or declined). */
families.put("/:id", async (c) => {
  const db = c.env.DB;
  const userId = c.get("userId");
  const familyId = Number(c.req.param("id"));
  const fam = await getFamily(db, familyId);
  const famName = name((await readJson(c)).name, 40);
  const ownPending = fam.status !== "approved" && fam.createdBy === userId && (await familyRole(db, userId, familyId)) !== null;
  if (!ownPending) await requireFamilyAdmin(db, userId, familyId);
  await db.prepare("UPDATE families SET name = ? WHERE id = ?").bind(famName, familyId).run();
  await notifyFamily(c.env, familyId);
  return c.body(null, 204);
});

/**
 * Makes a live member of family `:id` an admin of it. The caller must be an admin of an approved
 * `:id`; `sig` is their identity key over the v2 promotion message (which binds the family id).
 * Family #1 also mirrors the proof into `users` for the pre-family clients.
 */
families.post("/:id/admins/:userId", async (c) => {
  const db = c.env.DB;
  const familyId = Number(c.req.param("id"));
  const userId = c.req.param("userId");
  const by = c.get("userId");
  if (!Number.isSafeInteger(familyId) || familyId < 1) throw new ApiError("not_found");
  if ((await familyRole(db, by, familyId)) !== "admin") throw new ApiError("forbidden");
  const fam = await db.prepare("SELECT status FROM families WHERE id = ?").bind(familyId).first<{ status: string }>();
  if (fam?.status !== "approved") throw new ApiError("forbidden");
  const sig = signature((await readJson(c)).sig);
  const signer = await db.prepare("SELECT identity_pub FROM users WHERE id = ?").bind(by).first<string>("identity_pub");
  if (!signer || !(await verifyEd25519(signer, sig, promotionMessageV2(familyId, userId, by)))) {
    throw new ApiError("invalid_request");
  }
  const member = await db.prepare(
    `SELECT 1 AS ok FROM family_members m JOIN users u ON u.id = m.user_id
     WHERE m.family_id = ? AND m.user_id = ? AND u.deleted_at IS NULL`,
  ).bind(familyId, userId).first();
  if (!member) throw new ApiError("not_found");
  const stmts = [
    db.prepare(
      `UPDATE family_members SET role = 'admin', admin_by = ?, admin_signer_pub = ?, admin_sig = ?
       WHERE family_id = ? AND user_id = ? AND EXISTS (SELECT 1 FROM users WHERE id = ? AND deleted_at IS NULL)`,
    ).bind(by, signer, sig, familyId, userId, userId),
  ];
  if (familyId === FAMILY_ONE) {
    stmts.push(
      db.prepare("UPDATE users SET is_admin = 1, admin_by = ?, admin_signer_pub = ?, admin_sig = ? WHERE id = ? AND deleted_at IS NULL")
        .bind(by, signer, sig, userId),
    );
  }
  await db.batch(stmts);
  await logEvent(db, { kind: "admin_promoted", userId, actorId: by, payload: { familyId } });
  return c.body(null, 204);
});

/** Creates a member invite for family `:id`. Its admin only, while the family is approved. */
families.post("/:id/invites", async (c) => {
  const familyId = Number(c.req.param("id"));
  const body = await readJson(c);
  await requireFamilyAdmin(c.env.DB, c.get("userId"), familyId);
  if ("email" in body) throw new ApiError("invalid_request");
  const inviteName = name(body.name, 40);
  return c.json(await createInvite(c.env, inviteName, false, c.get("userId"), familyId), 201);
});

/** An invite anyone signed in can use to join an existing family: unused, live, for an approved family. */
const USABLE_INVITE = `i.used_by IS NULL AND i.revoked_at IS NULL AND i.expires_at > ? AND i.user_id IS NULL
  AND i.reviewer = 0 AND f.status = 'approved' AND f.hidden = 0`;

async function usableInvite(db: D1Database, token: unknown) {
  if (typeof token !== "string" || token.length === 0 || token.length > 200) throw new ApiError("invite_invalid");
  const row = await db.prepare(
    `SELECT i.family_id, i.name, f.name AS family_name
     FROM invites i JOIN families f ON f.id = i.family_id
     WHERE i.token_hash = ? AND ${USABLE_INVITE}`,
  ).bind(await sha256Hex(token), Date.now()).first<{ family_id: number; name: string; family_name: string }>();
  if (!row) throw new ApiError("invite_invalid");
  return row;
}

/** What a family invite is for, so the app can ask before joining. */
families.post("/invite-lookup", async (c) => {
  const inv = await usableInvite(c.env.DB, (await readJson(c)).inviteToken);
  const role = await familyRole(c.env.DB, c.get("userId"), inv.family_id);
  return c.json({ familyId: inv.family_id, familyName: inv.family_name, invitedName: inv.name, alreadyMember: role !== null });
});

/** Joins family `:id` with an invite, using an account I already have. */
families.post("/:id/join", async (c) => {
  const db = c.env.DB;
  const userId = c.get("userId");
  const familyId = Number(c.req.param("id"));
  const token = (await readJson(c)).inviteToken;
  await getFamily(db, familyId);
  const inv = await usableInvite(db, token);
  if (inv.family_id !== familyId) throw new ApiError("invite_invalid");
  if ((await familyRole(db, userId, familyId)) !== null) throw new ApiError("conflict");
  const hash = await sha256Hex(token as string);
  const now = Date.now();
  const [claim] = await db.batch([
    db.prepare(
      `UPDATE invites SET used_by = ?, used_at = ?
       WHERE token_hash = ? AND family_id = ? AND used_by IS NULL AND revoked_at IS NULL AND expires_at > ?
         AND user_id IS NULL AND reviewer = 0
         AND EXISTS (SELECT 1 FROM families f WHERE f.id = invites.family_id AND f.status = 'approved' AND f.hidden = 0)
         AND NOT EXISTS (SELECT 1 FROM family_members WHERE family_id = ? AND user_id = ?)`,
    ).bind(userId, now, hash, familyId, now, familyId, userId),
    db.prepare(
      `INSERT INTO family_members (family_id, user_id, role, joined_at)
       SELECT ?, ?, 'member', ? WHERE EXISTS (SELECT 1 FROM invites WHERE token_hash = ? AND used_by = ? AND used_at = ?)`,
    ).bind(familyId, userId, now, hash, userId, now),
    eventStmt(db, { kind: "family_joined", userId, actorId: userId, payload: { familyId }, at: now }, {
      sql: "EXISTS (SELECT 1 FROM invites WHERE token_hash = ? AND used_by = ? AND used_at = ?)",
      binds: [hash, userId, now],
    }),
  ]);
  if (claim.meta.changes !== 1) throw new ApiError("invite_invalid");
  await notifyFamily(c.env, familyId);
  await sharesChanged(c.env);
  const row = await db.prepare(`${FAMILY_SELECT} WHERE f.id = ?`).bind(userId, familyId).first<FamilyRow>();
  return c.json({ family: familyOut(row!, userId) });
});
