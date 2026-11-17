import { Hono } from "hono";
import type { AppEnv } from "../env";
import { ApiError } from "../lib/errors";
import { FAMILY_ONE, familyRole } from "../lib/family";
import { logEvent, promotionMessageV2, signature, verifyEd25519 } from "../lib/reset";
import { readJson } from "../lib/validate";
import { requireAuth } from "../middleware/auth";

export const families = new Hono<AppEnv>();

/**
 * Makes a live member of family `:id` an admin of it. The caller must be an admin of an approved
 * `:id`; `sig` is their identity key over the v2 promotion message (which binds the family id).
 * Family #1 also mirrors the proof into `users` for the pre-family clients.
 */
families.post("/:id/admins/:userId", requireAuth, async (c) => {
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
