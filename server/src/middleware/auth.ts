import { createMiddleware } from "hono/factory";
import type { AppEnv } from "../env";
import { ApiError } from "../lib/errors";
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
    "SELECT u.reviewer FROM devices d JOIN users u ON u.id = d.user_id WHERE d.id = ? AND d.user_id = ? AND d.revoked_at IS NULL",
  )
    .bind(claims.dev, claims.sub)
    .first<{ reviewer: number }>();
  if (!live) throw new ApiError("unauthorized");
  c.set("userId", claims.sub);
  c.set("deviceId", claims.dev);
  c.set("isAdmin", claims.adm);
  // A reviewer account (docs/protocol.md "Reviewer accounts") sees only other reviewers.
  c.set("reviewer", live.reviewer === 1);
  await next();
});

/**
 * Admin status comes from the database, so a promotion counts at once (not after a refresh).
 * A reviewer account is never an admin, whatever its row says.
 */
export const requireAdmin = createMiddleware<AppEnv>(async (c, next) => {
  const row = await c.env.DB.prepare("SELECT is_admin, reviewer FROM users WHERE id = ?").bind(c.get("userId"))
    .first<{ is_admin: number; reviewer: number }>();
  if (row?.is_admin !== 1 || row.reviewer !== 0) throw new ApiError("forbidden");
  c.set("isAdmin", true);
  await next();
});
