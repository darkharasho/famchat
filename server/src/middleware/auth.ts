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
    "SELECT 1 FROM devices WHERE id = ? AND user_id = ? AND revoked_at IS NULL",
  )
    .bind(claims.dev, claims.sub)
    .first();
  if (!live) throw new ApiError("unauthorized");
  c.set("userId", claims.sub);
  c.set("deviceId", claims.dev);
  c.set("isAdmin", claims.adm);
  await next();
});

/** Admin status comes from the database, so a promotion counts at once (not after a refresh). */
export const requireAdmin = createMiddleware<AppEnv>(async (c, next) => {
  const isAdmin = await c.env.DB.prepare("SELECT is_admin FROM users WHERE id = ?").bind(c.get("userId")).first<number>("is_admin");
  if (isAdmin !== 1) throw new ApiError("forbidden");
  c.set("isAdmin", true);
  await next();
});
