// The push queue's consumer: turns a PushJob into one FCM message per device token of the offline
// members. The text comes from metadata the server already has (names, group title), never from
// the message, which the server can't read anyway. Each push also carries the user's unread total
// for the app-icon badge, and BadgeJobs (a chat read on another device) carry only that.
import type { Env } from "../env";
import { BADGE_PLATFORMS, type BadgeJob, isBadgeJob, type PushJob, type QueueJob } from "../hub";
import {
  accessToken,
  type Fetch,
  fcmBadgeMessage,
  fcmMessage,
  fcmPreviewMessage,
  invalidateAccessToken,
  type Notification,
  parseServiceAccount,
  type PreviewData,
  type SendResult,
  type ServiceAccount,
  sendFcm,
} from "./fcm";

/** Tries per device: the first send plus this many re-queued retries. */
export const MAX_ATTEMPTS = 3;
export const RETRY_DELAY_S = 10;

export interface Delivery {
  deviceId: string;
  result: SendResult;
}

const liveFetch: Fetch = (input, init) => fetch(input, init);

/** The service account, or null when push is off (no secret, or a broken one: logged). */
export function serviceAccount(env: Env): ServiceAccount | null {
  if (!env.FCM_SERVICE_ACCOUNT) return null;
  try {
    return parseServiceAccount(env.FCM_SERVICE_ACCOUNT);
  } catch (e) {
    console.error("FCM_SERVICE_ACCOUNT is not a service-account key", e instanceof Error ? e.message : "");
    return null;
  }
}

export async function handlePushBatch(batch: MessageBatch<QueueJob>, env: Env, fetcher: Fetch = liveFetch): Promise<void> {
  const sa = serviceAccount(env);
  if (!sa) {
    batch.ackAll(); // push is off until scripts/setup-firebase.sh has run
    return;
  }
  for (const msg of batch.messages) {
    try {
      const job = msg.body;
      if (isBadgeJob(job)) await deliverBadgeJob(env, sa, job, fetcher);
      else await deliverJob(env, sa, job, fetcher);
      msg.ack();
    } catch (e) {
      console.error("push job failed", e);
      msg.retry({ delaySeconds: RETRY_DELAY_S });
    }
  }
}

/** Direct chat: "<sender>" / "New message". Group: "<title>" / "New message from <sender>" (or
 * "<sender> mentioned you"). */
export async function notificationFor(db: D1Database, job: PushJob): Promise<Notification | null> {
  const row = await db.prepare(
    `SELECT c.kind, c.title, u.name AS sender FROM chats c, users u WHERE c.id = ? AND u.id = ?`,
  ).bind(job.chatId, job.senderUserId).first<{ kind: string; title: string | null; sender: string }>();
  if (!row) return null;
  if (row.kind === "direct") return { title: row.sender, body: "New message", chatId: job.chatId };
  const body = job.mention ? `${row.sender} mentioned you` : `New message from ${row.sender}`;
  return { title: row.title || "Group", body, chatId: job.chatId };
}

/**
 * Each of [userIds]' app-icon badge: the messages of others after their read point and after they
 * joined, not silent (reactions, edits, deletes), in chats they haven't muted. The app counts the
 * same way (chat_db.dart watchChatList), except that it also leaves out messages their sender
 * deleted, which the server can't see; it corrects the badge whenever it runs. Users with nothing
 * unread map to 0.
 */
export async function unreadTotals(db: D1Database, userIds: string[], now = Date.now()): Promise<Map<string, number>> {
  const totals = new Map(userIds.map((u) => [u, 0]));
  if (userIds.length === 0) return totals;
  // Per membership, a seq range on the messages primary key (chat_id, seq).
  const { results } = await db.prepare(
    `SELECT m.user_id, COUNT(*) AS n FROM chat_members m
     JOIN messages x ON x.chat_id = m.chat_id AND x.seq > MAX(m.last_read_seq, m.joined_seq)
       AND x.silent = 0 AND x.sender_user_id <> m.user_id
     WHERE m.user_id IN (${userIds.map(() => "?").join(",")})
       AND (m.muted_until IS NULL OR m.muted_until <= ?)
     GROUP BY m.user_id`,
  ).bind(...userIds, now).all<{ user_id: string; n: number }>();
  for (const r of results) totals.set(r.user_id, r.n);
  return totals;
}

/** [unreadTotals], or none (pushes go out without a badge) when the count fails. */
async function badgesOrNone(db: D1Database, userIds: string[]): Promise<Map<string, number>> {
  try {
    return await unreadTotals(db, userIds);
  } catch (e) {
    console.error("unread totals failed", e);
    return new Map();
  }
}

/** Sends [job] to every live device with a token of its users who are still members. */
export async function deliverJob(env: Env, sa: ServiceAccount, job: PushJob, fetcher: Fetch): Promise<Delivery[]> {
  if (!Array.isArray(job.userIds) || job.userIds.length === 0) return [];
  const note = await notificationFor(env.DB, job);
  if (!note) return [];
  const users = job.userIds.slice(0, 100);
  const { results } = await env.DB.prepare(
    `SELECT d.id, d.user_id, d.push_token, d.push_previews FROM devices d
     JOIN chat_members m ON m.user_id = d.user_id AND m.chat_id = ?
     WHERE d.user_id IN (${users.map(() => "?").join(",")})
       AND d.revoked_at IS NULL AND d.push_token IS NOT NULL`,
  ).bind(job.chatId, ...users).all<{ id: string; user_id: string; push_token: string; push_previews: number }>();
  const only = job.deviceIds ? new Set(job.deviceIds) : null;
  const matched = results.filter((d) => !only || only.has(d.id));
  const badges = matched.length ? await badgesOrNone(env.DB, [...new Set(matched.map((d) => d.user_id))]) : new Map();
  const targets = matched.map(({ user_id, ...d }) => ({ ...d, badge: badges.get(user_id) }));
  const deliveries = await sendAll(env, sa, targets, note, fetcher, job.preview && {
    messageId: job.messageId,
    senderUserId: job.senderUserId,
    ...job.preview,
  });

  const retry = deliveries.filter((d) => d.result === "retry").map((d) => d.deviceId);
  const attempt = (job.attempt ?? 0) + 1;
  if (retry.length && attempt < MAX_ATTEMPTS && env.PUSH_QUEUE) {
    // After FCM calls went out, nothing may throw: a retry of the whole job would notify the devices
    // that already got it a second time.
    await env.PUSH_QUEUE.send(
      { chatId: job.chatId, senderUserId: job.senderUserId, messageId: job.messageId, userIds: job.userIds, deviceIds: retry, attempt, ...(job.mention ? { mention: true } : {}), ...(job.preview ? { preview: job.preview } : {}) },
      { delaySeconds: RETRY_DELAY_S * attempt },
    ).catch((e) => console.error("push retry not queued", e));
  }
  return deliveries;
}

/**
 * Sends [job]'s user's unread total to the job's devices that are still theirs, live, phones and
 * holding a token. Failed sends are re-queued like message pushes; a retry counts again.
 */
export async function deliverBadgeJob(env: Env, sa: ServiceAccount, job: BadgeJob, fetcher: Fetch): Promise<Delivery[]> {
  if (typeof job.userId !== "string" || !Array.isArray(job.deviceIds) || job.deviceIds.length === 0) return [];
  const ids = job.deviceIds.slice(0, 100);
  const { results } = await env.DB.prepare(
    `SELECT id, push_token FROM devices WHERE user_id = ? AND id IN (${ids.map(() => "?").join(",")})
     AND revoked_at IS NULL AND push_token IS NOT NULL AND platform IN (${BADGE_PLATFORMS.map(() => "?").join(",")})`,
  ).bind(job.userId, ...ids, ...BADGE_PLATFORMS).all<{ id: string; push_token: string }>();
  if (results.length === 0) return [];
  const badge = (await unreadTotals(env.DB, [job.userId])).get(job.userId) ?? 0;
  const deliveries = await sendMessages(env, sa, results, (d) => fcmBadgeMessage(d.push_token, badge), fetcher);
  const retry = deliveries.filter((d) => d.result === "retry").map((d) => d.deviceId);
  const attempt = (job.attempt ?? 0) + 1;
  if (retry.length && attempt < MAX_ATTEMPTS && env.PUSH_QUEUE) {
    await env.PUSH_QUEUE.send({ kind: "badge", userId: job.userId, deviceIds: retry, attempt }, { delaySeconds: RETRY_DELAY_S * attempt })
      .catch((e) => console.error("badge retry not queued", e));
  }
  return deliveries;
}

type Target = { id: string; push_token: string; push_previews?: number; badge?: number };

/**
 * Sends [note] to each device, with its user's [Target.badge] when known; clears dead tokens. One
 * access-token renewal after a 401.
 */
export async function sendAll(
  env: Env,
  sa: ServiceAccount,
  devices: Target[],
  note: Notification,
  fetcher: Fetch,
  preview?: PreviewData,
): Promise<Delivery[]> {
  // Previews only for devices that switched them on, and only when the job carries the envelope.
  const messageFor = (d: Target) =>
    d.push_previews === 1 && preview
      ? fcmPreviewMessage(d.push_token, note, preview, env.APP_ORIGIN, d.badge)
      : fcmMessage(d.push_token, note, env.APP_ORIGIN, d.badge);
  return sendMessages(env, sa, devices, messageFor, fetcher);
}

/** Sends each device its [messageFor] message; clears dead tokens. One access-token renewal after a 401. */
async function sendMessages<D extends { id: string; push_token: string }>(
  env: Env,
  sa: ServiceAccount,
  devices: D[],
  messageFor: (d: D) => object,
  fetcher: Fetch,
): Promise<Delivery[]> {
  if (devices.length === 0) return [];
  const sendEach = async (ds: typeof devices) => {
    const tok = await accessToken(sa, fetcher);
    return Promise.all(ds.map(async (d) => ({ d, result: await sendFcm(sa, tok, messageFor(d), fetcher) })));
  };
  let sent = await sendEach(devices);
  const refused = sent.filter((s) => s.result === "auth").map((s) => s.d);
  if (refused.length) {
    invalidateAccessToken();
    const again = await sendEach(refused).catch((e) => {
      console.error("fcm token renewal failed", e);
      return refused.map((d) => ({ d, result: "retry" as SendResult }));
    });
    sent = [...sent.filter((s) => s.result !== "auth"), ...again.map((s) => ({ ...s, result: s.result === "auth" ? ("retry" as const) : s.result }))];
  }
  const stale = sent.filter((s) => s.result === "stale");
  if (stale.length) {
    await env.DB.batch(
      stale.map((s) => env.DB.prepare("UPDATE devices SET push_token = NULL, push_previews = 0 WHERE id = ? AND push_token = ?").bind(s.d.id, s.d.push_token)),
    ).catch((e) => console.error("stale tokens not cleared", e)); // cleared on the next push
  }
  return sent.map((s) => ({ deviceId: s.d.id, result: s.result }));
}
