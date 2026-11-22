// Shared queries and checks for chats, members and wrapped chat keys.
import { b64urlDecode } from "./encoding";
import { ApiError } from "./errors";
import { allReadAfterLeaveStmt } from "./timing";

const ULID = /^[0-9A-HJKMNP-TV-Z]{26}$/;

export function isUlid(v: unknown): v is string {
  return typeof v === "string" && ULID.test(v);
}

export interface MemberOut {
  userId: string;
  joinedSeq: number;
  lastReadSeq: number;
}

export interface ChatOut {
  id: string;
  kind: "direct" | "group";
  title: string | null;
  createdBy: string;
  currentEpoch: number;
  epochReady: boolean;
  lastSeq: number;
  lastMessageAt: number | null;
  createdAt: number;
  /** The family a group belongs to; null for direct chats. */
  familyId: number | null;
  /** The caller's own mute: no pushes from this chat until then (Unix ms), or null. */
  mutedUntil: number | null;
  /** The caller's own pin (Unix ms when pinned), or null. */
  pinnedAt: number | null;
  /** When the caller archived the chat (Unix ms), or null. */
  archivedAt: number | null;
  /** The caller marked the chat as unread. */
  markedUnread: boolean;
  /** A group's photo (GET /chats/:id/avatar?v=<avatarKey>), or null. */
  avatarKey: string | null;
  /** The disappearing-message timer in seconds, or null (off). */
  disappearSecs: number | null;
  /** The last change of the timer: who, when, and the chat's lastSeq then (null if never changed). */
  disappearChangedBy: string | null;
  disappearChangedAt: number | null;
  disappearChangedSeq: number | null;
  members: MemberOut[];
}

/** The caller's own state for a chat (mute, pin, archive, marked unread). */
type Mine = { muted_until: number | null; pinned_at: number | null; archived_at: number | null; marked_unread: number };

const NOT_MINE: Mine = { muted_until: null, pinned_at: null, archived_at: null, marked_unread: 0 };

type ChatRow = {
  id: string;
  kind: "direct" | "group";
  title: string | null;
  created_by: string;
  current_epoch: number;
  epoch_ready: number;
  last_seq: number;
  last_message_at: number | null;
  created_at: number;
  family_id: number | null;
  avatar_key: string | null;
  disappear_secs: number | null;
  disappear_changed_by: string | null;
  disappear_changed_at: number | null;
  disappear_changed_seq: number | null;
};

const CHAT_SELECT = `SELECT c.id, c.kind, c.title, c.created_by, c.current_epoch, c.last_seq, c.last_message_at, c.created_at, c.family_id, c.avatar_key,
  c.disappear_secs, c.disappear_changed_by, c.disappear_changed_at, c.disappear_changed_seq,
  EXISTS (SELECT 1 FROM chat_epochs e WHERE e.chat_id = c.id AND e.epoch = c.current_epoch) AS epoch_ready
  FROM chats c`;

function toOut(r: ChatRow, members: MemberOut[], mine: Mine): ChatOut {
  return {
    id: r.id,
    kind: r.kind,
    title: r.title,
    createdBy: r.created_by,
    currentEpoch: r.current_epoch,
    epochReady: r.epoch_ready === 1,
    lastSeq: r.last_seq,
    lastMessageAt: r.last_message_at,
    createdAt: r.created_at,
    familyId: r.family_id,
    mutedUntil: mine.muted_until,
    pinnedAt: mine.pinned_at,
    archivedAt: mine.archived_at,
    markedUnread: mine.marked_unread === 1,
    avatarKey: r.avatar_key,
    disappearSecs: r.disappear_secs,
    disappearChangedBy: r.disappear_changed_by,
    disappearChangedAt: r.disappear_changed_at,
    disappearChangedSeq: r.disappear_changed_seq,
    members,
  };
}

/** Chats where [userId] is a member, with their member lists. */
export async function chatsOf(db: D1Database, userId: string): Promise<ChatOut[]> {
  const [chats, members] = await db.batch([
    db.prepare(
      `${CHAT_SELECT} WHERE c.id IN (SELECT chat_id FROM chat_members WHERE user_id = ?) ORDER BY COALESCE(c.last_message_at, c.created_at) DESC`,
    ).bind(userId),
    db.prepare(
      `SELECT m.chat_id, m.user_id, m.joined_seq, m.last_read_seq, ${MINE_COLS} FROM chat_members m
       WHERE m.chat_id IN (SELECT chat_id FROM chat_members WHERE user_id = ?) ORDER BY m.joined_at, m.user_id`,
    ).bind(userId),
  ]);
  const byChat = new Map<string, MemberOut[]>();
  const mine = new Map<string, Mine>();
  for (const m of members.results as MemberRow[]) {
    const list = byChat.get(m.chat_id) ?? [];
    list.push({ userId: m.user_id, joinedSeq: m.joined_seq, lastReadSeq: m.last_read_seq });
    byChat.set(m.chat_id, list);
    if (m.user_id === userId) mine.set(m.chat_id, m);
  }
  return (chats.results as ChatRow[]).map((r) => toOut(r, byChat.get(r.id) ?? [], mine.get(r.id) ?? NOT_MINE));
}

const MINE_COLS = "muted_until, pinned_at, archived_at, marked_unread";

type MemberRow = Mine & { chat_id: string; user_id: string; joined_seq: number; last_read_seq: number };

/** The chat as [viewer] sees it (their own mute). */
export async function chatOut(db: D1Database, chatId: string, viewer: string): Promise<ChatOut | null> {
  const [chat, members] = await db.batch([
    db.prepare(`${CHAT_SELECT} WHERE c.id = ?`).bind(chatId),
    db.prepare(
      `SELECT chat_id, user_id, joined_seq, last_read_seq, ${MINE_COLS} FROM chat_members WHERE chat_id = ? ORDER BY joined_at, user_id`,
    ).bind(chatId),
  ]);
  const r = chat.results[0] as ChatRow | undefined;
  if (!r) return null;
  const rows = members.results as MemberRow[];
  return toOut(
    r,
    rows.map((m) => ({ userId: m.user_id, joinedSeq: m.joined_seq, lastReadSeq: m.last_read_seq })),
    rows.find((m) => m.user_id === viewer) ?? NOT_MINE,
  );
}

export async function isMember(db: D1Database, chatId: string, userId: string): Promise<boolean> {
  return !!(await db.prepare("SELECT 1 FROM chat_members WHERE chat_id = ? AND user_id = ?").bind(chatId, userId).first());
}

export async function memberIds(db: D1Database, chatId: string): Promise<string[]> {
  const { results } = await db.prepare("SELECT user_id FROM chat_members WHERE chat_id = ?").bind(chatId)
    .all<{ user_id: string }>();
  return results.map((r) => r.user_id);
}

/**
 * [userId] leaves group [chatId]: the chat moves to a new epoch and keeps them as a leaver. With
 * [when], every statement only acts while that condition holds (its binds follow the statement's own).
 */
export function leaveGroupStmts(
  db: D1Database,
  chatId: string,
  userId: string,
  now: number,
  when?: { sql: string; binds: unknown[] },
): D1PreparedStatement[] {
  const and = when ? ` AND ${when.sql}` : "";
  const b = when?.binds ?? [];
  return [
    db.prepare(`DELETE FROM chat_members WHERE chat_id = ? AND user_id = ?${and}`).bind(chatId, userId, ...b),
    db.prepare(`DELETE FROM starred_messages WHERE chat_id = ? AND user_id = ?${and}`).bind(chatId, userId, ...b),
    db.prepare(`DELETE FROM reminders WHERE chat_id = ? AND user_id = ?${and}`).bind(chatId, userId, ...b),
    // They no longer hold back disappearing messages they hadn't read (the hub re-arms its alarm).
    allReadAfterLeaveStmt(db, chatId, now, when),
    db.prepare(`UPDATE chats SET current_epoch = current_epoch + 1 WHERE id = ?${and}`).bind(chatId, ...b),
    db.prepare(`INSERT OR REPLACE INTO chat_leavers (chat_id, user_id, left_at) SELECT ?, ?, ? WHERE ${when?.sql ?? "1"}`)
      .bind(chatId, userId, now, ...b),
  ];
}

/** The chat if [userId] is a member, else not_found. */
export async function requireMemberChat(db: D1Database, chatId: string, userId: string): Promise<ChatOut> {
  const chat = await chatOut(db, chatId, userId);
  if (!chat || !chat.members.some((m) => m.userId === userId)) throw new ApiError("not_found");
  return chat;
}

export async function liveDeviceIds(db: D1Database, userIds: string[]): Promise<string[]> {
  if (userIds.length === 0) return [];
  const { results } = await db.prepare(
    `SELECT id FROM devices WHERE revoked_at IS NULL AND user_id IN (${userIds.map(() => "?").join(",")})`,
  ).bind(...userIds).all<{ id: string }>();
  return results.map((r) => r.id);
}

export interface WrapIn {
  chatId: string;
  epoch: number;
  recipientDeviceId: string;
  wrapperDeviceId: string;
  sealed: string;
  sig: string;
}

const MIN_SEALED = 32 + 24 + 16;
export const MAX_WRAPS = 500;

/** Parses a wraps array; any malformed wrap is invalid_request. */
export function parseWraps(v: unknown, max = MAX_WRAPS): WrapIn[] {
  if (!Array.isArray(v) || v.length > max) throw new ApiError("invalid_request");
  return v.map((w) => {
    if (!w || typeof w !== "object") throw new ApiError("invalid_request");
    const o = w as Record<string, unknown>;
    const ok =
      typeof o.chatId === "string" &&
      Number.isInteger(o.epoch) && (o.epoch as number) >= 1 && (o.epoch as number) <= 0xffffffff &&
      typeof o.recipientDeviceId === "string" && o.recipientDeviceId.length > 0 &&
      typeof o.wrapperDeviceId === "string" && o.wrapperDeviceId.length > 0 &&
      typeof o.sealed === "string" && typeof o.sig === "string";
    if (!ok) throw new ApiError("invalid_request");
    const sealed = b64urlDecode(o.sealed as string);
    const sig = b64urlDecode(o.sig as string);
    if (sealed.length < MIN_SEALED || sealed.length > 1024 || sig.length !== 64) throw new ApiError("invalid_request");
    return {
      chatId: o.chatId as string,
      epoch: o.epoch as number,
      recipientDeviceId: o.recipientDeviceId as string,
      wrapperDeviceId: o.wrapperDeviceId as string,
      sealed: o.sealed as string,
      sig: o.sig as string,
    };
  });
}

/**
 * The wraps for [epoch] must be exactly one per device in [deviceIds], all for [chatId] and made by
 * [wrapper]; otherwise wraps_mismatch. Wraps for other epochs are left to the caller.
 */
export function checkCoverage(
  wraps: WrapIn[],
  o: { chatId: string; epoch: number; wrapper: string; deviceIds: string[] },
): void {
  const want = new Set(o.deviceIds);
  const seen = new Set<string>();
  for (const w of wraps) {
    if (w.chatId !== o.chatId || w.wrapperDeviceId !== o.wrapper) throw new ApiError("wraps_mismatch");
    if (w.epoch !== o.epoch) continue;
    if (!want.has(w.recipientDeviceId) || seen.has(w.recipientDeviceId)) throw new ApiError("wraps_mismatch");
    seen.add(w.recipientDeviceId);
  }
  if (seen.size !== want.size) throw new ApiError("wraps_mismatch");
}

export function wrapInserts(db: D1Database, wraps: WrapIn[], now: number): D1PreparedStatement[] {
  return wraps.map((w) =>
    db.prepare(
      `INSERT OR IGNORE INTO chat_key_wraps (chat_id, epoch, device_id, wrapper_device_id, sealed, sig, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?)`,
    ).bind(w.chatId, w.epoch, w.recipientDeviceId, w.wrapperDeviceId, w.sealed, w.sig, now),
  );
}

export function wrapOut(r: { chat_id: string; epoch: number; device_id: string; wrapper_device_id: string; sealed: string; sig: string }) {
  return {
    chatId: r.chat_id,
    epoch: r.epoch,
    recipientDeviceId: r.device_id,
    wrapperDeviceId: r.wrapper_device_id,
    sealed: r.sealed,
    sig: r.sig,
  };
}
