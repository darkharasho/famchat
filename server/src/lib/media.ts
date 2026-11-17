// Media quota: the family's media must fit R2's 10 GB free tier. After an upload pushes live media
// past MEDIA_CAP, the oldest objects are deleted until the total is below MEDIA_TARGET, their rows get
// expired_at, and each affected chat's members get {type:"media_expired", chatId, keys}.
import type { Env } from "../env";
import { memberIds } from "./chatdb";

const MiB = 1024 * 1024;
const GiB = 1024 * MiB;

export const MEDIA_CAP = 8 * GiB;
export const MEDIA_TARGET = 7.5 * GiB;
/** All reviewer accounts' live media together (docs/protocol.md "Reviewer accounts"). */
export const REVIEWER_MEDIA_CAP = 256 * 1024 * 1024;

/** Largest ciphertext per kind. Voice: 10 minutes of ~48 kbps AAC is about 3.6 MB (the client checks duration). */
export const KIND_LIMITS: ReadonlyMap<string, number> = new Map([
  ["photo", 15 * MiB],
  ["thumb", 1 * MiB],
  ["voice", 8 * MiB],
  // Under the 100 MB request body limit of Workers on the Free and Pro plans.
  ["video", 64 * MiB],
]);

export async function mediaUsage(db: D1Database): Promise<number> {
  const row = await db.prepare("SELECT bytes FROM media_usage WHERE id = 1").first<{ bytes: number }>();
  return row?.bytes ?? 0;
}

type Row = { key: string; chat_id: string; uploader_id: string; message_id: string | null; bytes: number };

export type Notify = (userIds: string[], event: Record<string, unknown>) => Promise<void>;

const PAGE = 500;
/** D1 allows 100 bound parameters per statement. */
const PARAM_CHUNK = 90;

function chunks<T>(xs: T[], n: number): T[][] {
  const out: T[][] = [];
  for (let i = 0; i < xs.length; i += n) out.push(xs.slice(i, i + n));
  return out;
}

/**
 * If live media exceeds [cap], expires the oldest objects (a message's blobs together) until the
 * total is below [target]. Returns the expired keys. Not safe to run concurrently with itself:
 * FamilyHub serializes calls.
 */
export async function evictOldest(env: Env, notify: Notify, cap = MEDIA_CAP, target = MEDIA_TARGET): Promise<string[]> {
  const db = env.DB;
  const usage = await mediaUsage(db);
  if (usage <= cap) return [];

  const taken = new Map<string, Row>();
  let freed = 0;
  for (let offset = 0; usage - freed >= target; offset += PAGE) {
    const { results } = await db.prepare(
      `SELECT key, chat_id, uploader_id, message_id, bytes FROM media WHERE expired_at IS NULL
       ORDER BY created_at, key LIMIT ? OFFSET ?`,
    ).bind(PAGE, offset).all<Row>();
    if (results.length === 0) break;
    for (const r of results) {
      if (usage - freed < target) break;
      taken.set(r.key, r);
      freed += r.bytes;
    }
  }
  // A photo and its thumbnail go together: same (client-supplied) message id, chat and uploader.
  const group = (r: Row) => `${r.message_id}|${r.chat_id}|${r.uploader_id}`;
  const groups = new Set([...taken.values()].filter((r) => r.message_id).map(group));
  const messageIds = [...new Set([...taken.values()].map((r) => r.message_id).filter((m): m is string => !!m))];
  for (const ids of chunks(messageIds, PARAM_CHUNK)) {
    const { results } = await db.prepare(
      `SELECT key, chat_id, uploader_id, message_id, bytes FROM media WHERE expired_at IS NULL
       AND message_id IN (${ids.map(() => "?").join(",")})`,
    ).bind(...ids).all<Row>();
    for (const r of results) if (groups.has(group(r))) taken.set(r.key, r);
  }
  const keys = [...taken.keys()];
  if (keys.length === 0) return [];

  const now = Date.now();
  await db.batch(
    chunks(keys, PARAM_CHUNK).map((ks) =>
      db.prepare(`UPDATE media SET expired_at = ? WHERE expired_at IS NULL AND key IN (${ks.map(() => "?").join(",")})`)
        .bind(now, ...ks),
    ),
  );
  for (const ks of chunks(keys, 1000)) {
    try {
      await env.MEDIA.delete(ks);
    } catch (e) {
      // The rows are expired either way; an orphaned object only costs storage.
      console.error("R2 delete failed", e);
    }
  }

  const byChat = new Map<string, string[]>();
  for (const r of taken.values()) byChat.set(r.chat_id, [...(byChat.get(r.chat_id) ?? []), r.key]);
  for (const [chatId, ks] of byChat) {
    await notify(await memberIds(db, chatId), { type: "media_expired", chatId, keys: ks });
  }
  return keys;
}
