import { Hono } from "hono";
import type { AppEnv } from "../env";
import { ApiError } from "../lib/errors";
import { getFamily, notifyFamily } from "../lib/family";
import { logEvent } from "../lib/reset";
import { requireAuth, requireOperator } from "../middleware/auth";

export const operator = new Hono<AppEnv>();
operator.use(requireAuth, requireOperator);

const STATUSES = ["pending", "approved", "declined"];

interface OperatorFamilyRow {
  id: number;
  name: string;
  status: string;
  created_at: number;
  decided_at: number | null;
  creator_id: string | null;
  creator_name: string | null;
  member_count: number;
}

/** Families in one status (default pending), newest first. The hidden reviewer family is never listed. */
operator.get("/families", async (c) => {
  const status = c.req.query("status") ?? "pending";
  if (!STATUSES.includes(status)) throw new ApiError("invalid_request");
  const { results } = await c.env.DB.prepare(
    `SELECT f.id, f.name, f.status, f.created_at, f.decided_at, u.id AS creator_id, u.name AS creator_name,
       (SELECT COUNT(*) FROM family_members x JOIN users m ON m.id = x.user_id AND m.deleted_at IS NULL
        WHERE x.family_id = f.id) AS member_count
     FROM families f LEFT JOIN users u ON u.id = f.created_by
     WHERE f.hidden = 0 AND f.status = ? ORDER BY f.created_at DESC, f.id DESC`,
  ).bind(status).all<OperatorFamilyRow>();
  return c.json({
    families: results.map((r) => ({
      id: r.id,
      name: r.name,
      status: r.status,
      createdAt: r.created_at,
      decidedAt: r.decided_at,
      creator: r.creator_id ? { id: r.creator_id, name: r.creator_name } : null,
      memberCount: r.member_count,
    })),
  });
});

for (const [action, status] of [["approve", "approved"], ["decline", "declined"]] as const) {
  operator.post(`/families/:id/${action}`, async (c) => {
    const db = c.env.DB;
    const userId = c.get("userId");
    const fam = await getFamily(db, Number(c.req.param("id")));
    // The status guard makes a concurrent double decision lose cleanly.
    const res = await db.prepare(
      "UPDATE families SET status = ?, decided_at = ?, decided_by = ? WHERE id = ? AND status = 'pending'",
    ).bind(status, Date.now(), userId, fam.id).run();
    if (!res.meta.changes) throw new ApiError("conflict");
    await logEvent(db, { kind: `family_${status}`, userId: fam.createdBy, actorId: userId, payload: { familyId: fam.id, name: fam.name } });
    await notifyFamily(c.env, fam.id);
    return c.body(null, 204);
  });
}
