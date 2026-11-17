import { createMiddleware } from "hono/factory";
import type { AppEnv } from "../env";
import { ApiError } from "../lib/errors";
import { FAMILY_ONE, familyRole, isAnyAdmin, REVIEWER_FAMILY } from "../lib/family";
import { verifyAccessToken } from "../lib/tokens";

export function bearer(header: string | undefined): string | null {
  const m = header?.match(/^Bearer (.+)$/);
  return m ? m[1] : null;
}

export const requireAuth = createMiddleware<AppEnv>(async (c, next) => {
  const token = bearer(c.req.header("authorization"));
  const claims = token ? await verifyAccessToken(c.env, token) : null;
  if (!claims) throw new ApiError("unauthorized");
  const live = await c.env.DB.prepare(
    `SELECT u.operator, EXISTS (SELECT 1 FROM family_members m WHERE m.user_id = u.id AND m.family_id = ?) AS reviewer
     FROM devices d JOIN users u ON u.id = d.user_id
     WHERE d.id = ? AND d.user_id = ? AND d.revoked_at IS NULL`,
  )
    .bind(REVIEWER_FAMILY, claims.dev, claims.sub)
    .first<{ reviewer: number; operator: number }>();
  if (!live) throw new ApiError("unauthorized");
  c.set("userId", claims.sub);
  c.set("deviceId", claims.dev);
  c.set("isAdmin", claims.adm);
  // A reviewer account (docs/protocol.md "Reviewer accounts") sees only other reviewers.
  c.set("reviewer", live.reviewer === 1);
  c.set("operator", live.operator === 1);
  await next();
});

/** Admin of family #1 (the original family), read from the database so a promotion counts at once. */
export const requireAdmin = createMiddleware<AppEnv>(async (c, next) => {
  if ((await familyRole(c.env.DB, c.get("userId"), FAMILY_ONE)) !== "admin") throw new ApiError("forbidden");
  c.set("isAdmin", true);
  await next();
});

/** Admin of any non-hidden family. */
export const requireAnyAdmin = createMiddleware<AppEnv>(async (c, next) => {
  if (!(await isAnyAdmin(c.env.DB, c.get("userId")))) throw new ApiError("forbidden");
  await next();
});

export const requireOperator = createMiddleware<AppEnv>(async (c, next) => {
  if (!c.get("operator")) throw new ApiError("forbidden");
  await next();
});
