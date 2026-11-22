// Batch 4 timing rules shared by the hub and the routes (docs/protocol.md "Scheduled messages",
// "Reminders", "Disappearing messages"). Times are Unix ms; timers are seconds.

const DAY_MS = 86_400_000;

/** The disappearing-message timers a chat may have (null is off). */
export const DISAPPEAR_SECS: ReadonlySet<number> = new Set([86_400, 604_800, 7_776_000]);

/** The server deletes a disappearing message at the latest this long after sent + timer. */
export const BACKSTOP_MS = 30 * DAY_MS;

/** Scheduled sends and reminders: at least this far ahead... */
export const MIN_AHEAD_MS = 60_000;
/** ...and at most this far. */
export const MAX_AHEAD_MS = 366 * DAY_MS;

/** Tombstones of deleted messages are kept this long: the longest timer + the backstop + a day. */
export const TOMBSTONE_KEEP_MS = 121 * DAY_MS;

/** Whether [at] is an allowed time for a scheduled send or reminder, seen at [now]. */
export function validAhead(at: unknown, now: number): at is number {
  return Number.isSafeInteger(at) && (at as number) >= now + MIN_AHEAD_MS && (at as number) <= now + MAX_AHEAD_MS;
}

/** Retry delay after [attempts] failures of a due item: 1 min, doubling, at most an hour. */
export function retryDelay(attempts: number): number {
  return Math.min(60_000 * 2 ** Math.max(0, attempts - 1), 3_600_000);
}

/** Failures before a scheduled send is marked failed or a reminder dropped. */
export const MAX_ATTEMPTS = 6;

/**
 * Moves [chatId]'s disappearing messages with seq in (afterSeq, uptoSeq] that every current member
 * other than their sender has now read to delete at [now] + their timer (never later than they were).
 * Binds: now, chatId, afterSeq, uptoSeq. RETURNING the new delete_at values.
 */
export const ALL_READ_SQL = `UPDATE messages SET delete_at = ?1 + disappear_secs * 1000
  WHERE chat_id = ?2 AND seq > ?3 AND seq <= ?4 AND disappear_secs IS NOT NULL
    AND delete_at > ?1 + disappear_secs * 1000
    AND NOT EXISTS (SELECT 1 FROM chat_members cm WHERE cm.chat_id = messages.chat_id
      AND cm.user_id <> messages.sender_user_id AND cm.last_read_seq < messages.seq)`;

/**
 * [ALL_READ_SQL] over the whole chat, for after someone left (they no longer hold messages back).
 * With [when], it only acts while that condition holds (its binds follow).
 */
export function allReadAfterLeaveStmt(
  db: D1Database,
  chatId: string,
  now: number,
  when?: { sql: string; binds: unknown[] },
): D1PreparedStatement {
  return db.prepare(`${ALL_READ_SQL}${when ? ` AND ${when.sql}` : ""}`)
    .bind(now, chatId, 0, Number.MAX_SAFE_INTEGER, ...(when?.binds ?? []));
}
