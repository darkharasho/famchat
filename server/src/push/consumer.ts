// The push queue's consumer: turns a PushJob into one FCM message per device token of the offline
// members. The text comes from metadata the server already has (names, group title), never from
// the message, which the server can't read anyway.
import type { Env } from "../env";
import type { PushJob } from "../hub";
import {
  accessToken,
  type Fetch,
  invalidateAccessToken,
  type Notification,
  parseServiceAccount,
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

export async function handlePushBatch(batch: MessageBatch<PushJob>, env: Env, fetcher: Fetch = liveFetch): Promise<void> {
  const sa = serviceAccount(env);
  if (!sa) {
    batch.ackAll(); // push is off until scripts/setup-firebase.sh has run
    return;
  }
  for (const msg of batch.messages) {
    try {
      await deliverJob(env, sa, msg.body, fetcher);
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

/** Sends [job] to every live device with a token of its users who are still members. */
export async function deliverJob(env: Env, sa: ServiceAccount, job: PushJob, fetcher: Fetch): Promise<Delivery[]> {
  if (!Array.isArray(job.userIds) || job.userIds.length === 0) return [];
  const note = await notificationFor(env.DB, job);
  if (!note) return [];
  const users = job.userIds.slice(0, 100);
  const { results } = await env.DB.prepare(
    `SELECT d.id, d.push_token FROM devices d
     JOIN chat_members m ON m.user_id = d.user_id AND m.chat_id = ?
     WHERE d.user_id IN (${users.map(() => "?").join(",")})
       AND d.revoked_at IS NULL AND d.push_token IS NOT NULL`,
  ).bind(job.chatId, ...users).all<{ id: string; push_token: string }>();
  const only = job.deviceIds ? new Set(job.deviceIds) : null;
  const targets = results.filter((d) => !only || only.has(d.id));
  const deliveries = await sendAll(env, sa, targets, note, fetcher);

  const retry = deliveries.filter((d) => d.result === "retry").map((d) => d.deviceId);
  const attempt = (job.attempt ?? 0) + 1;
  if (retry.length && attempt < MAX_ATTEMPTS && env.PUSH_QUEUE) {
    // After FCM calls went out, nothing may throw: a retry of the whole job would notify the devices
    // that already got it a second time.
    await env.PUSH_QUEUE.send(
      { chatId: job.chatId, senderUserId: job.senderUserId, messageId: job.messageId, userIds: job.userIds, deviceIds: retry, attempt, ...(job.mention ? { mention: true } : {}) },
      { delaySeconds: RETRY_DELAY_S * attempt },
    ).catch((e) => console.error("push retry not queued", e));
  }
  return deliveries;
}

/** Sends [note] to each device; clears dead tokens. One access-token renewal after a 401. */
export async function sendAll(
  env: Env,
  sa: ServiceAccount,
  devices: { id: string; push_token: string }[],
  note: Notification,
  fetcher: Fetch,
): Promise<Delivery[]> {
  if (devices.length === 0) return [];
  const sendEach = async (ds: typeof devices) => {
    const tok = await accessToken(sa, fetcher);
    return Promise.all(ds.map(async (d) => ({ d, result: await sendFcm(sa, tok, d.push_token, note, env.APP_ORIGIN, fetcher) })));
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
      stale.map((s) => env.DB.prepare("UPDATE devices SET push_token = NULL WHERE id = ? AND push_token = ?").bind(s.d.id, s.d.push_token)),
    ).catch((e) => console.error("stale tokens not cleared", e)); // cleared on the next push
  }
  return sent.map((s) => ({ deviceId: s.d.id, result: s.result }));
}
