import { Hono } from "hono";
import type { AppEnv, Env } from "../env";
import { ApiError } from "../lib/errors";
import { MEDIA_CAP, MEDIA_TARGET, mediaUsage } from "../lib/media";
import { randomToken, sha256Hex } from "../lib/tokens";
import { name, readJson } from "../lib/validate";
import { bearer, requireAdmin, requireAuth } from "../middleware/auth";

export const INVITE_TTL_MS = 7 * 24 * 60 * 60 * 1000;

async function timingSafeEqual(a: string, b: string): Promise<boolean> {
  const [ha, hb] = await Promise.all([sha256Hex(a), sha256Hex(b)]);
  let diff = 0;
  for (let i = 0; i < ha.length; i++) diff |= ha.charCodeAt(i) ^ hb.charCodeAt(i);
  return diff === 0;
}

/** Bootstrap invites (createdBy = null) are only inserted while no user exists, in the same statement. */
async function createInvite(env: Env, inviteName: string, makeAdmin: boolean, createdBy: string | null) {
  const token = randomToken();
  const now = Date.now();
  const expiresAt = now + INVITE_TTL_MS;
  const res = await env.DB.prepare(
    `INSERT INTO invites (token_hash, name, make_admin, created_by, created_at, expires_at)
     SELECT ?, ?, ?, ?, ?, ? WHERE ? IS NOT NULL OR NOT EXISTS (SELECT 1 FROM users)`,
  )
    .bind(await sha256Hex(token), inviteName, makeAdmin ? 1 : 0, createdBy, now, expiresAt, createdBy)
    .run();
  if (res.meta.changes !== 1) throw new ApiError("already_bootstrapped");
  return { inviteToken: token, inviteUrl: `${env.APP_ORIGIN}/join#${token}`, expiresAt };
}

export const admin = new Hono<AppEnv>();

admin.post("/bootstrap", async (c) => {
  const secret = bearer(c.req.header("authorization"));
  if (!secret || !c.env.BOOTSTRAP_SECRET || !(await timingSafeEqual(secret, c.env.BOOTSTRAP_SECRET))) {
    throw new ApiError("unauthorized");
  }
  const inviteName = name((await readJson(c)).name, 40);
  return c.json(await createInvite(c.env, inviteName, true, null), 201);
});

admin.post("/invites", requireAuth, requireAdmin, async (c) => {
  const inviteName = name((await readJson(c)).name, 40);
  return c.json(await createInvite(c.env, inviteName, false, c.get("userId")), 201);
});

/** Media storage: live bytes against the cap, and how many objects are live or expired. */
admin.get("/usage", requireAuth, requireAdmin, async (c) => {
  const counts = await c.env.DB.prepare(
    "SELECT COALESCE(SUM(expired_at IS NULL), 0) AS live, COALESCE(SUM(expired_at IS NOT NULL), 0) AS expired FROM media",
  ).first<{ live: number; expired: number }>();
  return c.json({
    usedBytes: await mediaUsage(c.env.DB),
    capBytes: MEDIA_CAP,
    evictToBytes: MEDIA_TARGET,
    files: counts?.live ?? 0,
    expiredFiles: counts?.expired ?? 0,
  });
});
