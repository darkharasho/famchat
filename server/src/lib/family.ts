import type { Env } from "../env";
import { hubStub } from "../hub";
import { notify } from "../notify";
import { leaveGroupStmts, memberIds } from "./chatdb";
import { ApiError } from "./errors";

/** The original family, and the hidden family that holds reviewer accounts. */
export const FAMILY_ONE = 1;
export const REVIEWER_FAMILY = 2;

/** Binds the user id once: every live user sharing a family with them, themselves included. */
export const PEERS_SQL = `SELECT DISTINCT b.user_id FROM family_members a
  JOIN family_members b ON b.family_id = a.family_id
  JOIN users u ON u.id = b.user_id AND u.deleted_at IS NULL
  WHERE a.user_id = ?`;

/** Like PEERS_SQL but includes deleted accounts (the directory still lists them). */
export const DIRECTORY_PEERS_SQL = `SELECT DISTINCT b.user_id FROM family_members a
  JOIN family_members b ON b.family_id = a.family_id
  WHERE a.user_id = ?`;

/** Live users who share any family with [userId], [userId] included (when live). */
export async function familyPeers(db: D1Database, userId: string): Promise<string[]> {
  const { results } = await db.prepare(PEERS_SQL).bind(userId).all<{ user_id: string }>();
  return results.map((r) => r.user_id);
}

/** True when both users are live and share a family. */
export async function shares(db: D1Database, a: string, b: string): Promise<boolean> {
  const row = await db.prepare(
    `SELECT 1 AS ok FROM family_members x
     JOIN family_members y ON y.family_id = x.family_id
     JOIN users ux ON ux.id = x.user_id AND ux.deleted_at IS NULL
     JOIN users uy ON uy.id = y.user_id AND uy.deleted_at IS NULL
     WHERE x.user_id = ? AND y.user_id = ? LIMIT 1`,
  ).bind(a, b).first();
  return row !== null;
}

export async function familyRole(
  db: D1Database,
  userId: string,
  familyId: number,
): Promise<"admin" | "member" | null> {
  const row = await db.prepare("SELECT role FROM family_members WHERE family_id = ? AND user_id = ?")
    .bind(familyId, userId).first<{ role: "admin" | "member" }>();
  return row?.role ?? null;
}

/** Admin of any approved, non-hidden family (a pending or declined family gives no admin power). */
export async function isAnyAdmin(db: D1Database, userId: string): Promise<boolean> {
  const row = await db.prepare(
    `SELECT 1 AS ok FROM family_members m JOIN families f ON f.id = m.family_id
     WHERE m.user_id = ? AND m.role = 'admin' AND f.hidden = 0 AND f.status = 'approved' LIMIT 1`,
  ).bind(userId).first();
  return row !== null;
}

/**
 * The family a new group chat belongs to. An explicit id must be an integer naming an approved family
 * the user is in. Without one: the user's only approved family, else family #1 if they are in it.
 */
export async function groupFamilyFor(db: D1Database, userId: string, requested: unknown): Promise<number> {
  const { results } = await db.prepare(
    `SELECT m.family_id FROM family_members m JOIN families f ON f.id = m.family_id
     WHERE m.user_id = ? AND f.status = 'approved' ORDER BY m.family_id`,
  ).bind(userId).all<{ family_id: number }>();
  const ids = results.map((r) => r.family_id);
  if (requested !== undefined && requested !== null) {
    if (typeof requested !== "number" || !Number.isInteger(requested) || !ids.includes(requested)) {
      throw new ApiError("invalid_request");
    }
    return requested;
  }
  if (ids.length === 1) return ids[0];
  if (ids.includes(FAMILY_ONE)) return FAMILY_ONE;
  throw new ApiError("invalid_request");
}

/** [userId] and everyone who shares a chat with them and a family: who hears about that user's devices. */
export async function sharingUserIds(db: D1Database, userId: string): Promise<string[]> {
  const { results } = await db.prepare(
    `SELECT DISTINCT user_id FROM chat_members
     WHERE chat_id IN (SELECT chat_id FROM chat_members WHERE user_id = ?)
       AND user_id IN (${PEERS_SQL})`,
  ).bind(userId, userId).all<{ user_id: string }>();
  return [...new Set([userId, ...results.map((r) => r.user_id)])];
}

/** Tells the hub that family membership changed. Never throws: the hub recovers on its own. */
export async function sharesChanged(env: Env): Promise<void> {
  try {
    await hubStub(env).sharesChanged();
  } catch (e) {
    console.error("hub sharesChanged failed", e);
  }
}

export interface FamilyInfo {
  id: number;
  name: string;
  status: string;
  createdBy: string | null;
}

/** Live members of a family. */
export async function familyMemberIds(db: D1Database, familyId: number): Promise<string[]> {
  const { results } = await db.prepare(
    `SELECT m.user_id FROM family_members m JOIN users u ON u.id = m.user_id AND u.deleted_at IS NULL
     WHERE m.family_id = ?`,
  ).bind(familyId).all<{ user_id: string }>();
  return results.map((r) => r.user_id);
}

/** Tells every live member of a family (plus [extra]) that it changed: `GET /families`. */
export async function notifyFamily(env: Env, familyId: number, extra: string[] = []): Promise<void> {
  const ids = await familyMemberIds(env.DB, familyId);
  await notify(env, [...new Set([...ids, ...extra])], { type: "family", familyId });
}

/** A non-hidden family by id, else not_found. */
export async function getFamily(db: D1Database, familyId: number): Promise<FamilyInfo> {
  const row = Number.isSafeInteger(familyId) && familyId >= 1
    ? await db.prepare("SELECT id, name, status, created_by FROM families WHERE id = ? AND hidden = 0")
        .bind(familyId).first<{ id: number; name: string; status: string; created_by: string | null }>()
    : null;
  if (!row) throw new ApiError("not_found");
  return { id: row.id, name: row.name, status: row.status, createdBy: row.created_by };
}

/** The family, if [userId] is an admin of it and it is approved: not_found if unknown or hidden, else forbidden. */
export async function requireFamilyAdmin(db: D1Database, userId: string, familyId: number): Promise<FamilyInfo> {
  const fam = await getFamily(db, familyId);
  if ((await familyRole(db, userId, familyId)) !== "admin" || fam.status !== "approved") throw new ApiError("forbidden");
  return fam;
}

/**
 * For an UPDATE of `families` whose owner [userId] is going: the longest-serving other live admin
 * (`MIN(joined_at)`, then `user_id`), else NULL. Binds [userId] once.
 */
export const NEXT_OWNER_SQL = `(SELECT m.user_id FROM family_members m JOIN users u ON u.id = m.user_id AND u.deleted_at IS NULL
  WHERE m.family_id = families.id AND m.role = 'admin' AND m.user_id <> ?
  ORDER BY m.joined_at, m.user_id LIMIT 1)`;

/** Clears the family #1 admin mirror on `users` (demotion or removal). */
export const clearUserAdminStmt = (db: D1Database, userId: string) =>
  db.prepare("UPDATE users SET is_admin = 0, admin_by = NULL, admin_signer_pub = NULL, admin_sig = NULL WHERE id = ?")
    .bind(userId);

/**
 * Takes [userId] out of family [familyId] (they leave, or an admin removes them), in one batch: they
 * leave each of the family's groups they are in (as a chat leave or removal does), ownership passes on
 * if they owned it, and family #1's admin mirror is cleared. Then the chats, the family (them included)
 * and the hub are told. Checks (who may) are the caller's; the last-admin rule is enforced by the batch
 * itself: the membership delete does nothing when it would leave others in the family with no admin,
 * and then neither does any other statement. Returns false (and tells nobody) in that case.
 */
export async function removeFromFamily(env: Env, familyId: number, userId: string): Promise<boolean> {
  const db = env.DB;
  const { results } = await db.prepare(
    `SELECT c.id FROM chats c JOIN chat_members m ON m.chat_id = c.id AND m.user_id = ?
     WHERE c.family_id = ? AND c.kind = 'group'`,
  ).bind(userId, familyId).all<{ id: string }>();
  const chats = results.map((r) => r.id);
  const now = Date.now();
  const gone = {
    sql: "NOT EXISTS (SELECT 1 FROM family_members WHERE family_id = ? AND user_id = ?)",
    binds: [familyId, userId],
  };
  const stmts = [
    db.prepare(
      `DELETE FROM family_members WHERE family_id = ? AND user_id = ?
         AND (role <> 'admin'
           OR EXISTS (SELECT 1 FROM family_members a JOIN users ua ON ua.id = a.user_id AND ua.deleted_at IS NULL
                      WHERE a.family_id = ? AND a.role = 'admin' AND a.user_id <> ?)
           OR NOT EXISTS (SELECT 1 FROM family_members o JOIN users uo ON uo.id = o.user_id AND uo.deleted_at IS NULL
                          WHERE o.family_id = ? AND o.user_id <> ?))`,
    ).bind(familyId, userId, familyId, userId, familyId, userId),
    db.prepare(`UPDATE families SET created_by = ${NEXT_OWNER_SQL} WHERE id = ? AND created_by = ? AND ${gone.sql}`)
      .bind(userId, familyId, userId, ...gone.binds),
    ...chats.flatMap((chatId) => leaveGroupStmts(db, chatId, userId, now, gone)),
  ];
  if (familyId === FAMILY_ONE) {
    stmts.push(db.prepare(
      `UPDATE users SET is_admin = 0, admin_by = NULL, admin_signer_pub = NULL, admin_sig = NULL
       WHERE id = ? AND ${gone.sql}`,
    ).bind(userId, ...gone.binds));
  }
  const res = await db.batch(stmts);
  if (res[0].meta.changes !== 1) return false;
  for (const chatId of chats) {
    await notify(env, [userId], { type: "removed", chatId });
    await notify(env, await memberIds(db, chatId), { type: "chat", chatId });
  }
  await notifyFamily(env, familyId, [userId]);
  await sharesChanged(env);
  return true;
}
