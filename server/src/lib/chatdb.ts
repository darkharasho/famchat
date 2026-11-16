// Shared queries and checks for chats, members and wrapped chat keys.
import { b64urlDecode } from "./encoding";
import { ApiError } from "./errors";

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
  members: MemberOut[];
}

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
};

const CHAT_SELECT = `SELECT c.id, c.kind, c.title, c.created_by, c.current_epoch, c.last_seq, c.last_message_at, c.created_at,
  EXISTS (SELECT 1 FROM chat_epochs e WHERE e.chat_id = c.id AND e.epoch = c.current_epoch) AS epoch_ready
  FROM chats c`;

function toOut(r: ChatRow, members: MemberOut[]): ChatOut {
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
      `SELECT m.chat_id, m.user_id, m.joined_seq, m.last_read_seq FROM chat_members m
       WHERE m.chat_id IN (SELECT chat_id FROM chat_members WHERE user_id = ?) ORDER BY m.joined_at, m.user_id`,
    ).bind(userId),
  ]);
  const byChat = new Map<string, MemberOut[]>();
  for (const m of members.results as { chat_id: string; user_id: string; joined_seq: number; last_read_seq: number }[]) {
    const list = byChat.get(m.chat_id) ?? [];
    list.push({ userId: m.user_id, joinedSeq: m.joined_seq, lastReadSeq: m.last_read_seq });
    byChat.set(m.chat_id, list);
  }
  return (chats.results as ChatRow[]).map((r) => toOut(r, byChat.get(r.id) ?? []));
}

export async function chatOut(db: D1Database, chatId: string): Promise<ChatOut | null> {
  const [chat, members] = await db.batch([
    db.prepare(`${CHAT_SELECT} WHERE c.id = ?`).bind(chatId),
    db.prepare(
      "SELECT user_id, joined_seq, last_read_seq FROM chat_members WHERE chat_id = ? ORDER BY joined_at, user_id",
    ).bind(chatId),
  ]);
  const r = chat.results[0] as ChatRow | undefined;
  if (!r) return null;
  return toOut(
    r,
    (members.results as { user_id: string; joined_seq: number; last_read_seq: number }[]).map((m) => ({
      userId: m.user_id,
      joinedSeq: m.joined_seq,
      lastReadSeq: m.last_read_seq,
    })),
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

/** The chat if [userId] is a member, else not_found. */
export async function requireMemberChat(db: D1Database, chatId: string, userId: string): Promise<ChatOut> {
  const chat = await chatOut(db, chatId);
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
