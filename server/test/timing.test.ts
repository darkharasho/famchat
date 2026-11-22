// Batch 4: scheduled messages, reminders and disappearing messages (docs/protocol.md). The hub's
// clock is faked and its alarm handler called directly.
import { env, runInDurableObject } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { DUE_BATCH, type FamilyHub, noPush, type PushJob, type ReminderJob } from "../src/hub";
import { newId } from "../src/lib/ids";
import { evictOldest } from "../src/lib/media";
import { BACKSTOP_MS, MAX_ATTEMPTS, TOMBSTONE_KEEP_MS } from "../src/lib/timing";
import { signAccessToken } from "../src/lib/tokens";
import { deliverReminderJob } from "../src/push/consumer";
import { fcmReminderMessage, invalidateAccessToken, parseServiceAccount } from "../src/push/fcm";
import { addDevice, api, type ChatOut, createDirect, createGroup, insertMessage, type TestUser } from "./chat-helpers";
import { insertUserWithDevice, resetDb } from "./helpers";
import { download, insertMedia, upload, usage } from "./media-helpers";
import { fakeGoogle, testServiceAccount } from "./push-helpers";
import { closeSockets, socket } from "./ws-helpers";

const MIN = 60_000;
const DAY = 86_400_000;
const WEEK_S = 604_800;

const envelope = (epoch = 1, ct = "AAAAAAAAAAAAAAAAAAAAAA") => ({ v: 1, epoch, nonce: "AAAA", ct, sig: "AAAA" });

const stub = () => env.HUB.get(env.HUB.idFromName("family"));
const inHub = <T>(fn: (h: FamilyHub, s: DurableObjectState) => T | Promise<T>) => runInDurableObject(stub(), fn);
const setClock = (t: number) => inHub((h) => void (h.now = () => t));
/** Back to real time (a fake clock far ahead would count every socket as stale on the next send). */
const realClock = () => inHub((h) => void (h.now = Date.now));

/** Waits until [s] hears [userId]'s read position move. */
async function readBy(s: Awaited<ReturnType<typeof socket>>, userId: string) {
  for (;;) if ((await s.next("read")).userId === userId) return;
}
const runAlarm = () => inHub((h) => h.alarm());
const alarmAt = () => inHub((_, s) => s.storage.getAlarm());

/** Captures message and reminder push jobs. */
async function capturePushes() {
  const jobs: PushJob[] = [];
  const reminders: ReminderJob[] = [];
  await inHub((h) => {
    h.push = { notify: async (j) => void jobs.push(j) };
    h.reminderPush = { remind: async (j) => void reminders.push(j) };
  });
  return { jobs, reminders };
}

/** Another device of [u], with its own access token. */
async function otherDevice(u: TestUser): Promise<TestUser> {
  const deviceId = await addDevice(u.userId);
  return { ...u, deviceId, accessToken: await signAccessToken(env, { sub: u.userId, dev: deviceId, adm: false }) };
}

const schedule = (u: TestUser, id: string, body: Record<string, unknown>) => api(u.accessToken, "PUT", `/me/scheduled/${id}`, body);
type Scheduled = { id: string; chatId: string; senderDeviceId: string; envelope: unknown; deliverAt: number; state: string; createdAt: number; mentions: string[]; silent: boolean };
const scheduledOf = async (u: TestUser) =>
  (await (await api(u.accessToken, "GET", "/me/scheduled")).json<{ scheduled: Scheduled[] }>()).scheduled;
type Msg = { id: string; seq: number; senderDeviceId: string; disappearSecs?: number };
const history = async (u: TestUser, chatId: string) =>
  (await (await api(u.accessToken, "GET", `/chats/${chatId}/messages`)).json<{ messages: Msg[] }>()).messages;
const remindersOf = async (u: TestUser) =>
  (await (await api(u.accessToken, "GET", "/me/reminders")).json<{ reminders: { chatId: string; messageId: string; at: number }[] }>()).reminders;
const setTimer = (u: TestUser, chatId: string, disappearSecs: number | null) =>
  api(u.accessToken, "PATCH", `/chats/${chatId}`, { disappearSecs });
const msgRow = (id: string) =>
  env.DB.prepare("SELECT seq, disappear_secs, delete_at, created_at FROM messages WHERE id = ?").bind(id)
    .first<{ seq: number; disappear_secs: number | null; delete_at: number | null; created_at: number }>();

beforeEach(async () => {
  await resetDb();
  await inHub(async (h, s) => {
    h.now = Date.now;
    h.push = noPush;
    h.badges = { update: async () => {} };
    h.reminderPush = { remind: async () => {} };
    await s.storage.deleteAlarm();
  });
});
afterEach(async () => {
  closeSockets();
  await inHub((h) => void (h.now = Date.now));
});

describe("scheduled messages", () => {
  it("are stored, then delivered at their time with a new seq, an ack and fan-out", async () => {
    const a = await insertUserWithDevice({ name: "Mom" });
    const b = await insertUserWithDevice();
    const c = await insertUserWithDevice();
    await env.DB.prepare("UPDATE devices SET push_token = 'tok-c' WHERE id = ?").bind(c.deviceId).run();
    const chat = await createGroup(a, [b, c]);
    const { jobs } = await capturePushes();
    const sa = await socket(a);
    const sb = await socket(b);
    const t0 = Date.now();
    const id = newId();
    const res = await schedule(a, id, { chatId: chat.id, envelope: envelope(), deliverAt: t0 + 2 * MIN, mentions: [c.userId] });
    expect(res.status).toBe(201);
    expect((await res.json<{ scheduled: Scheduled }>()).scheduled).toMatchObject({
      id, chatId: chat.id, senderDeviceId: a.deviceId, deliverAt: t0 + 2 * MIN, state: "pending", mentions: [c.userId], silent: false,
    });
    await sa.next("scheduled");
    expect(await alarmAt()).toBe(t0 + 2 * MIN);
    expect(await history(b, chat.id)).toEqual([]);
    await sb.none("msg");

    // Not yet due: nothing happens.
    await setClock(t0 + MIN);
    await runAlarm();
    expect(await history(b, chat.id)).toEqual([]);

    await setClock(t0 + 2 * MIN + 1000);
    await runAlarm();
    expect(await sa.next("ack")).toEqual({ type: "ack", id, seq: 1, createdAt: t0 + 2 * MIN + 1000 });
    const msg = (await sb.next("msg")) as { message: Msg; mentions?: string[] };
    expect(msg.message).toMatchObject({ id, seq: 1, senderDeviceId: a.deviceId });
    expect(msg.mentions).toEqual([c.userId]);
    await sa.next("msg"); // the sender's own devices see it in the timeline
    await sa.next("scheduled");
    expect((await history(b, chat.id)).map((m) => m.id)).toEqual([id]);
    expect(await scheduledOf(a)).toEqual([]);
    expect(await alarmAt()).toBeNull();
    await expect.poll(() => jobs.length).toBe(1);
    expect(jobs[0]).toMatchObject({ chatId: chat.id, messageId: id, senderUserId: a.userId, userIds: [c.userId], mention: true });
    // Delivered once.
    await runAlarm();
    await sb.none("msg");
  });

  it("are idempotent on their id, replaceable from any device of the sender, and private", async () => {
    const a = await insertUserWithDevice();
    const b = await insertUserWithDevice();
    const chat = await createGroup(a, [b]);
    const laptop = await otherDevice(a);
    const sl = await socket(laptop);
    const sb = await socket(b);
    const t0 = Date.now();
    const id = newId();
    const body = { chatId: chat.id, envelope: envelope(), deliverAt: t0 + 10 * MIN };
    expect((await schedule(a, id, body)).status).toBe(201);
    await sl.next("scheduled");
    const again = await schedule(a, id, body);
    expect(again.status).toBe(200);
    await sl.none("scheduled");
    expect(await scheduledOf(a)).toHaveLength(1);

    // Edit from the laptop: new envelope and time.
    const edited = await schedule(laptop, id, { ...body, envelope: envelope(1, "BBBBBBBB"), deliverAt: t0 + 20 * MIN, silent: true });
    expect(edited.status).toBe(200);
    await sl.next("scheduled");
    const [row] = await scheduledOf(a);
    expect(row).toMatchObject({ senderDeviceId: laptop.deviceId, envelope: envelope(1, "BBBBBBBB"), deliverAt: t0 + 20 * MIN, silent: true });
    expect(await alarmAt()).toBe(t0 + 20 * MIN);

    // Nobody else sees it, or can take its id.
    expect(await scheduledOf(b)).toEqual([]);
    await sb.none("scheduled");
    expect((await schedule(b, id, body)).status).toBe(409);
    expect((await api(b.accessToken, "DELETE", `/me/scheduled/${id}`)).status).toBe(404);
    expect((await api(b.accessToken, "POST", `/me/scheduled/${id}/send`)).status).toBe(404);
    // An id already used by a message is a conflict.
    const used = await insertMessage(chat.id, a);
    expect((await schedule(a, used, body)).status).toBe(409);
  });

  it("refuse bad times, non-members, stale epochs and malformed bodies", async () => {
    const a = await insertUserWithDevice();
    const b = await insertUserWithDevice();
    const stranger = await insertUserWithDevice();
    const chat = await createGroup(a, [b]);
    const now = Date.now();
    const ok = { chatId: chat.id, envelope: envelope(), deliverAt: now + 5 * MIN };
    expect((await schedule(a, newId(), { ...ok, deliverAt: now + 30_000 })).status).toBe(400);
    expect((await schedule(a, newId(), { ...ok, deliverAt: now + 367 * DAY })).status).toBe(400);
    expect((await schedule(a, newId(), { ...ok, deliverAt: "soon" })).status).toBe(400);
    expect((await schedule(a, newId(), { ...ok, envelope: { v: 1 } })).status).toBe(400);
    expect((await schedule(a, newId(), { ...ok, mentions: "x" })).status).toBe(400);
    expect((await schedule(a, "nope", ok)).status).toBe(400);
    expect((await schedule(stranger, newId(), ok)).status).toBe(404);
    const stale = await schedule(a, newId(), { ...ok, envelope: envelope(2) });
    expect(stale.status).toBe(409);
    expect(await stale.json()).toEqual({ error: "stale_epoch" });
    expect((await schedule(a, newId(), { ...ok, deliverAt: now + 365 * DAY })).status).toBe(201);
    expect(await env.DB.prepare("SELECT COUNT(*) AS n FROM scheduled_messages").first("n")).toBe(1);
  });

  it("can be cancelled (their media goes too) or sent now", async () => {
    const a = await insertUserWithDevice();
    const b = await insertUserWithDevice();
    const chat = await createGroup(a, [b]);
    const sa = await socket(a);
    const sb = await socket(b);
    const t0 = Date.now();
    const id = newId();
    const key = newId();
    expect((await upload(a, { chatId: chat.id, key, messageId: id }, new Uint8Array(100))).status).toBe(201);
    expect(await usage()).toBe(100);
    await schedule(a, id, { chatId: chat.id, envelope: envelope(), deliverAt: t0 + 5 * MIN });
    expect((await api(a.accessToken, "DELETE", `/me/scheduled/${id}`)).status).toBe(204);
    expect((await api(a.accessToken, "DELETE", `/me/scheduled/${id}`)).status).toBe(404);
    expect(await scheduledOf(a)).toEqual([]);
    expect(await usage()).toBe(0);
    expect(await env.MEDIA.get(key)).toBeNull();
    expect(await alarmAt()).toBeNull();

    const id2 = newId();
    await schedule(a, id2, { chatId: chat.id, envelope: envelope(), deliverAt: t0 + 5 * MIN });
    const now = await api(a.accessToken, "POST", `/me/scheduled/${id2}/send`);
    expect(now.status).toBe(200);
    expect(await now.json()).toEqual({ id: id2, seq: 1, createdAt: expect.any(Number) });
    expect(((await sb.next("msg")) as { message: Msg }).message.id).toBe(id2);
    expect((await sa.next("ack")).id).toBe(id2);
    expect(await scheduledOf(a)).toEqual([]);
    expect((await api(a.accessToken, "POST", `/me/scheduled/${id2}/send`)).status).toBe(404);
    expect(await alarmAt()).toBeNull();
  });

  it("whose epoch moved on need a resend, which delivers exactly once from any device", async () => {
    const a = await insertUserWithDevice();
    const b = await insertUserWithDevice();
    const chat = await createGroup(a, [b]);
    const laptop = await otherDevice(a);
    const sa = await socket(a);
    const sl = await socket(laptop);
    const sb = await socket(b);
    const t0 = Date.now();
    const id = newId();
    await schedule(a, id, { chatId: chat.id, envelope: envelope(1), deliverAt: t0 + 2 * MIN });
    // The key rotated meanwhile (someone left, a device was removed).
    await env.DB.batch([
      env.DB.prepare("UPDATE chats SET current_epoch = 2 WHERE id = ?").bind(chat.id),
      env.DB.prepare("INSERT INTO chat_epochs (chat_id, epoch, created_by_device, created_at) VALUES (?, 2, ?, 1)").bind(chat.id, b.deviceId),
    ]);
    await setClock(t0 + 3 * MIN);
    await runAlarm();
    expect(await sa.next("needs_resend")).toEqual({ type: "needs_resend", chatId: chat.id, id });
    expect(await sl.next("needs_resend")).toEqual({ type: "needs_resend", chatId: chat.id, id });
    await sb.none("msg");
    expect((await scheduledOf(a))[0].state).toBe("needs_resend");
    expect(await alarmAt()).toBeNull();
    // Waiting for a device: the alarm doesn't try again.
    await runAlarm();
    await sb.none("msg");
    await realClock();
    // "Send now" with the stale envelope can't go either.
    expect((await api(a.accessToken, "POST", `/me/scheduled/${id}/send`)).status).toBe(409);

    // Someone else can't take the id.
    sb.send({ type: "send", id, chatId: chat.id, envelope: envelope(2) });
    expect(await sb.next("error")).toEqual({ type: "error", id, error: "conflict" });

    // The laptop re-encrypts and sends it; then the phone does too (both saw the event).
    sl.send({ type: "send", id, chatId: chat.id, envelope: envelope(2) });
    const ack = await sl.next("ack");
    expect(ack).toMatchObject({ id, seq: 1 });
    expect(((await sb.next("msg")) as { message: Msg }).message).toMatchObject({ id, seq: 1, senderDeviceId: laptop.deviceId });
    expect((await sa.next("ack")).id).toBe(id);
    sa.send({ type: "send", id, chatId: chat.id, envelope: envelope(2) });
    expect(await sa.next("ack")).toEqual(ack);
    await sb.none("msg");
    expect(await env.DB.prepare("SELECT COUNT(*) AS n FROM messages WHERE id = ?").bind(id).first("n")).toBe(1);
    expect(await scheduledOf(a)).toEqual([]);
  });

  it("from a sender no longer in the chat are dropped, with their media", async () => {
    const a = await insertUserWithDevice();
    const b = await insertUserWithDevice();
    const c = await insertUserWithDevice();
    const chat = await createGroup(a, [b, c]);
    const t0 = Date.now();
    const id = newId();
    const key = newId();
    await upload(c, { chatId: chat.id, key, messageId: id }, new Uint8Array(50));
    expect((await schedule(c, id, { chatId: chat.id, envelope: envelope(), deliverAt: t0 + 2 * MIN })).status).toBe(201);
    expect((await api(a.accessToken, "DELETE", `/chats/${chat.id}/members/${c.userId}`)).status).toBe(204);
    expect(await scheduledOf(c)).toEqual([]); // only chats they're still in
    await setClock(t0 + 3 * MIN);
    await runAlarm();
    expect(await history(a, chat.id)).toEqual([]);
    expect(await env.DB.prepare("SELECT COUNT(*) AS n FROM scheduled_messages").first("n")).toBe(0);
    expect(await usage()).toBe(0);
    expect(await env.MEDIA.get(key)).toBeNull();
  });

  it("keep their media through quota eviction until delivered", async () => {
    const a = await insertUserWithDevice();
    const chat = await createGroup(a, [await insertUserWithDevice()]);
    const id = newId();
    const held = await insertMedia({ chatId: chat.id, uploader: a, bytes: 600, createdAt: 1000, messageId: id });
    const old = await insertMedia({ chatId: chat.id, uploader: a, bytes: 600, createdAt: 2000, messageId: newId() });
    await schedule(a, id, { chatId: chat.id, envelope: envelope(), deliverAt: Date.now() + 5 * MIN });
    expect(await evictOldest(env, async () => {}, 1000, 900)).toEqual([old]);
    expect((await download(a, held)).status).toBe(200);
  });

  it("a failing one is retried with backoff, then marked failed, without holding the rest back", async () => {
    const a = await insertUserWithDevice();
    const b = await insertUserWithDevice();
    const chat = await createGroup(a, [b]);
    const sa = await socket(a);
    const t0 = Date.now();
    const bad = newId();
    const good = newId();
    await schedule(a, bad, { chatId: chat.id, envelope: envelope(), deliverAt: t0 + 2 * MIN });
    await schedule(a, good, { chatId: chat.id, envelope: envelope(), deliverAt: t0 + 2 * MIN });
    type H = { deliverScheduled: (r: { id: string }) => Promise<unknown> };
    await inHub((h) => {
      const x = h as unknown as H;
      const orig = x.deliverScheduled.bind(h);
      x.deliverScheduled = async (r) => {
        if (r.id === bad) throw new Error("boom");
        return orig(r);
      };
    });
    let t = t0 + 3 * MIN;
    await setClock(t);
    await runAlarm();
    expect((await history(b, chat.id)).map((m) => m.id)).toEqual([good]);
    const row = () => env.DB.prepare("SELECT state, attempts, next_at FROM scheduled_messages WHERE id = ?").bind(bad)
      .first<{ state: string; attempts: number; next_at: number }>();
    expect(await row()).toEqual({ state: "pending", attempts: 1, next_at: t + MIN });
    expect(await alarmAt()).toBe(t + MIN);
    for (let i = 2; i <= MAX_ATTEMPTS; i++) {
      t = (await row())!.next_at;
      await setClock(t);
      await runAlarm();
    }
    expect((await row())!.state).toBe("failed");
    expect((await row())!.attempts).toBe(MAX_ATTEMPTS);
    expect(await alarmAt()).toBeNull();
    expect((await scheduledOf(a)).map((s) => [s.id, s.state])).toEqual([[bad, "failed"]]);
    await inHub((h) => void delete (h as unknown as Partial<H>).deliverScheduled);
    sa.send({ type: "ping" });
  });
});

describe("the hub alarm", () => {
  it("is always armed for the earliest due item of scheduled sends, reminders and deletions", async () => {
    const a = await insertUserWithDevice();
    const b = await insertUserWithDevice();
    const chat = await createGroup(a, [b]);
    const m = await insertMessage(chat.id, b);
    const t0 = Date.now();
    const id = newId();
    await schedule(a, id, { chatId: chat.id, envelope: envelope(), deliverAt: t0 + 10 * MIN });
    expect(await alarmAt()).toBe(t0 + 10 * MIN);
    await api(a.accessToken, "PUT", `/chats/${chat.id}/messages/${m}/reminder`, { at: t0 + 5 * MIN });
    expect(await alarmAt()).toBe(t0 + 5 * MIN);
    await env.DB.prepare("UPDATE messages SET disappear_secs = 86400, delete_at = ? WHERE id = ?").bind(t0 + 3 * MIN, m).run();
    await inHub((h) => h.timersChanged());
    expect(await alarmAt()).toBe(t0 + 3 * MIN);
    await api(a.accessToken, "DELETE", `/me/scheduled/${id}`);
    expect(await alarmAt()).toBe(t0 + 3 * MIN);
    // The deletion fires (its reminder goes with it); then nothing is left.
    await setClock(t0 + 3 * MIN);
    await runAlarm();
    expect(await msgRow(m)).toBeNull();
    expect(await alarmAt()).toBeNull();
  });

  it("works in batches and runs again at once while more is due", async () => {
    const a = await insertUserWithDevice();
    const chat = await createGroup(a, [await insertUserWithDevice()]);
    for (let i = 0; i < DUE_BATCH + 1; i++) await insertMessage(chat.id, a);
    const t = Date.now() + MIN;
    await env.DB.prepare("UPDATE messages SET disappear_secs = 86400, delete_at = ?").bind(t - 1).run();
    await setClock(t);
    await runAlarm();
    expect(await env.DB.prepare("SELECT COUNT(*) AS n FROM messages").first("n")).toBe(1);
    expect(await alarmAt()).toBe(t);
    await runAlarm();
    expect(await env.DB.prepare("SELECT COUNT(*) AS n FROM messages").first("n")).toBe(0);
    expect(await alarmAt()).toBeNull();
  });
});

describe("reminders", () => {
  it("are set, moved and cleared for the caller only", async () => {
    const a = await insertUserWithDevice();
    const b = await insertUserWithDevice();
    const stranger = await insertUserWithDevice();
    const chat = await createGroup(a, [b]);
    const other = await createGroup(b, [stranger]);
    const m = await insertMessage(chat.id, b);
    const elsewhere = await insertMessage(other.id, b);
    const sa = await socket(a);
    const sb = await socket(b);
    const t0 = Date.now();
    const path = `/chats/${chat.id}/messages/${m}/reminder`;
    expect((await api(a.accessToken, "PUT", path, { at: t0 + 5 * MIN })).status).toBe(204);
    await sa.next("reminders");
    await sb.none("reminders");
    expect((await api(a.accessToken, "PUT", path, { at: t0 + 7 * MIN })).status).toBe(204);
    expect(await remindersOf(a)).toEqual([{ chatId: chat.id, messageId: m, at: t0 + 7 * MIN }]);
    expect(await remindersOf(b)).toEqual([]);
    // Refused: bad times, strangers, a message of another chat.
    expect((await api(a.accessToken, "PUT", path, { at: t0 + 10_000 })).status).toBe(400);
    expect((await api(a.accessToken, "PUT", path, { at: t0 + 367 * DAY })).status).toBe(400);
    expect((await api(a.accessToken, "PUT", path, {})).status).toBe(400);
    expect((await api(stranger.accessToken, "PUT", path, { at: t0 + 5 * MIN })).status).toBe(404);
    expect((await api(stranger.accessToken, "DELETE", path)).status).toBe(404);
    expect((await api(a.accessToken, "PUT", `/chats/${chat.id}/messages/${elsewhere}/reminder`, { at: t0 + 5 * MIN })).status).toBe(404);
    expect((await api(a.accessToken, "DELETE", path)).status).toBe(204);
    expect((await api(a.accessToken, "DELETE", path)).status).toBe(204);
    expect(await remindersOf(a)).toEqual([]);
    expect(await alarmAt()).toBeNull();
  });

  it("fire once to every device of their owner: a frame to sockets, a push to the rest", async () => {
    const a = await insertUserWithDevice();
    const b = await insertUserWithDevice();
    const chat = await createDirect(a, b);
    const m = await insertMessage(chat.id, b);
    const laptop = await otherDevice(a);
    await env.DB.prepare("UPDATE devices SET push_token = 'tok' WHERE id IN (?, ?, ?)").bind(a.deviceId, laptop.deviceId, b.deviceId).run();
    const { reminders } = await capturePushes();
    const sa = await socket(a);
    const sb = await socket(b);
    const t0 = Date.now();
    await api(a.accessToken, "PUT", `/chats/${chat.id}/messages/${m}/reminder`, { at: t0 + 2 * MIN });
    await setClock(t0 + 2 * MIN);
    await runAlarm();
    expect(await sa.next("reminder")).toEqual({ type: "reminder", chatId: chat.id, messageId: m, at: t0 + 2 * MIN });
    await sb.none("reminder");
    const stored = await env.DB.prepare("SELECT envelope FROM messages WHERE id = ?").bind(m).first<string>("envelope");
    expect(reminders).toEqual([{
      kind: "reminder", userId: a.userId, chatId: chat.id, messageId: m, at: t0 + 2 * MIN, senderUserId: b.userId,
      deviceIds: [laptop.deviceId],
      preview: { senderDeviceId: b.deviceId, epoch: 1, envelope: stored },
    }]);
    expect(await remindersOf(a)).toEqual([]);
    expect(await alarmAt()).toBeNull();
    await runAlarm();
    await sa.none("reminder");
    expect(reminders).toHaveLength(1);
  });

  it("for a message that is gone, or a chat left, are dropped", async () => {
    const a = await insertUserWithDevice();
    const b = await insertUserWithDevice();
    const c = await insertUserWithDevice();
    const chat = await createGroup(a, [b, c]);
    const m = await insertMessage(chat.id, b);
    const sa = await socket(a);
    const t0 = Date.now();
    await api(a.accessToken, "PUT", `/chats/${chat.id}/messages/${m}/reminder`, { at: t0 + 2 * MIN });
    await api(c.accessToken, "PUT", `/chats/${chat.id}/messages/${m}/reminder`, { at: t0 + 2 * MIN });
    await api(c.accessToken, "DELETE", `/chats/${chat.id}/members/${c.userId}`);
    expect(await env.DB.prepare("SELECT COUNT(*) AS n FROM reminders WHERE user_id = ?").bind(c.userId).first("n")).toBe(0);
    await env.DB.prepare("DELETE FROM messages WHERE id = ?").bind(m).run();
    await setClock(t0 + 2 * MIN);
    await runAlarm();
    await sa.none("reminder");
    expect(await env.DB.prepare("SELECT COUNT(*) AS n FROM reminders").first("n")).toBe(0);
  });

  it("push as a reminder: plain or with the envelope for previews, to devices still in the chat", async () => {
    invalidateAccessToken();
    const a = await insertUserWithDevice({ name: "Mom" });
    const b = await insertUserWithDevice({ name: "Kid" });
    const chat = await createGroup(a, [b], "Family");
    const laptop = await addDevice(a.userId);
    await env.DB.prepare("UPDATE devices SET push_token = 'tok-phone', push_previews = 1 WHERE id = ?").bind(a.deviceId).run();
    await env.DB.prepare("UPDATE devices SET push_token = 'tok-laptop' WHERE id = ?").bind(laptop).run();
    const json = (await testServiceAccount()).json;
    const g = fakeGoogle();
    const job: ReminderJob = {
      kind: "reminder", userId: a.userId, chatId: chat.id, messageId: "M1", at: 5, senderUserId: b.userId,
      deviceIds: [a.deviceId, laptop],
      preview: { senderDeviceId: b.deviceId, epoch: 1, envelope: '{"v":1}' },
    };
    const out = await deliverReminderJob({ ...env, FCM_SERVICE_ACCOUNT: json }, parseServiceAccount(json), job, g.fetcher);
    expect(out.map((d) => d.result)).toEqual(["ok", "ok"]);
    type Sent = { message: { token: string; data: Record<string, string>; notification?: { title: string; body: string } } };
    const sent = g.sends().map((s) => JSON.parse(s.body) as Sent).sort((x, y) => x.message.token.localeCompare(y.message.token));
    expect(sent[0].message.token).toBe("tok-laptop");
    expect(sent[0].message.notification).toEqual({ title: "Reminder", body: "Family: message from Kid" });
    expect(sent[0].message.data).toEqual({ chatId: chat.id, type: "reminder", messageId: "M1", at: "5" });
    expect(sent[1].message.token).toBe("tok-phone");
    expect(sent[1].message.notification).toBeUndefined();
    expect(sent[1].message.data).toMatchObject({ type: "reminder", messageId: "M1", preview: "1", env: '{"v":1}', title: "Reminder" });
    // Gone from the chat: nothing.
    await api(a.accessToken, "DELETE", `/chats/${chat.id}/members/${a.userId}`);
    const g2 = fakeGoogle();
    await deliverReminderJob({ ...env, FCM_SERVICE_ACCOUNT: json }, parseServiceAccount(json), job, g2.fetcher);
    expect(g2.sends()).toEqual([]);
    // Its own tag, so it doesn't replace the chat's notification.
    const plain = fcmReminderMessage("t", { title: "Reminder", body: "x", chatId: "c" }, { chatId: "c", messageId: "m", at: 1 }, "https://o");
    expect((plain.message.android as { notification: { tag: string } }).notification.tag).toBe("reminder-m");
  });
});

describe("disappearing messages", () => {
  it("any member sets the timer; members hear of it and who changed it is recorded", async () => {
    const a = await insertUserWithDevice();
    const b = await insertUserWithDevice();
    const stranger = await insertUserWithDevice();
    const chat = await createGroup(a, [b]);
    await insertMessage(chat.id, a);
    const sa = await socket(a);
    const res = await setTimer(b, chat.id, WEEK_S);
    expect(res.status).toBe(200);
    const out = (await res.json<{ chat: ChatOut & Record<string, unknown> }>()).chat;
    expect(out).toMatchObject({ disappearSecs: WEEK_S, disappearChangedBy: b.userId, disappearChangedSeq: 1, title: "Family" });
    expect(out.disappearChangedAt).toEqual(expect.any(Number));
    expect(await sa.next("chat")).toEqual({ type: "chat", chatId: chat.id });
    // The same value again records nothing new.
    await setTimer(a, chat.id, WEEK_S);
    const again = (await (await api(a.accessToken, "GET", `/chats/${chat.id}`)).json<{ chat: Record<string, unknown> }>()).chat;
    expect(again.disappearChangedBy).toBe(b.userId);
    for (const bad of [3600, 0, "86400", 86400.5]) expect((await setTimer(a, chat.id, bad as number)).status).toBe(400);
    expect((await setTimer(stranger, chat.id, null)).status).toBe(404);
    // Direct chats too; a title there is still refused.
    const direct = await createDirect(a, b);
    expect((await setTimer(a, direct.id, 86_400)).status).toBe(200);
    expect((await api(a.accessToken, "PATCH", `/chats/${direct.id}`, { title: "x" })).status).toBe(400);
    expect((await api(a.accessToken, "PATCH", `/chats/${direct.id}`, {})).status).toBe(400);
  });

  it("messages carry the timer from delivery; turning it off leaves sent ones alone", async () => {
    const a = await insertUserWithDevice();
    const b = await insertUserWithDevice();
    const chat = await createGroup(a, [b]);
    await setTimer(a, chat.id, WEEK_S);
    const sa = await socket(a);
    const sb = await socket(b);
    const id = newId();
    sa.send({ type: "send", id, chatId: chat.id, envelope: envelope() });
    await sa.next("ack");
    expect(((await sb.next("msg")) as { message: Msg }).message.disappearSecs).toBe(WEEK_S);
    const row = await msgRow(id);
    expect(row).toMatchObject({ disappear_secs: WEEK_S, delete_at: row!.created_at + WEEK_S * 1000 + BACKSTOP_MS });
    expect(await alarmAt()).toBe(row!.delete_at);
    // A scheduled one takes the setting at delivery, not when scheduled.
    const t0 = Date.now();
    const sid = newId();
    await setTimer(a, chat.id, null);
    await schedule(a, sid, { chatId: chat.id, envelope: envelope(), deliverAt: t0 + 2 * MIN });
    await setTimer(a, chat.id, 86_400);
    await setClock(t0 + 2 * MIN);
    await runAlarm();
    expect(((await sb.next("msg")) as { message: Msg }).message).toMatchObject({ id: sid, disappearSecs: 86_400 });
    expect((await sa.next("ack")).id).toBe(sid);
    await realClock();
    await setTimer(a, chat.id, null);
    const id3 = newId();
    sa.send({ type: "send", id: id3, chatId: chat.id, envelope: envelope() });
    await sa.next("ack");
    const msgs = await history(b, chat.id);
    expect(msgs.map((m) => [m.id, m.disappearSecs])).toEqual([[id, WEEK_S], [sid, 86_400], [id3, undefined]]);
    expect((await msgRow(id))!.disappear_secs).toBe(WEEK_S);
  });

  it("are deleted with their media once every current member read them plus the timer", async () => {
    const a = await insertUserWithDevice();
    const b = await insertUserWithDevice();
    const c = await insertUserWithDevice();
    const stranger = await insertUserWithDevice();
    const chat = await createGroup(a, [b, c]);
    await setTimer(a, chat.id, WEEK_S);
    const sa = await socket(a);
    const sb = await socket(b);
    const sc = await socket(c);
    const m1 = newId();
    const m2 = newId();
    const key = newId();
    await upload(a, { chatId: chat.id, key, messageId: m1 }, new Uint8Array(80));
    for (const id of [m1, m2]) {
      sa.send({ type: "send", id, chatId: chat.id, envelope: envelope() });
      await sa.next("ack");
    }
    await api(b.accessToken, "PUT", `/chats/${chat.id}/messages/${m1}/star`);
    const t0 = Date.now();
    await api(c.accessToken, "PUT", `/chats/${chat.id}/messages/${m1}/reminder`, { at: t0 + 300 * DAY });
    const backstop = (await msgRow(m1))!.delete_at!;

    // b read both; c only m1. The sender (a) never reads: their own messages count as read.
    await setClock(t0 + 1000);
    sb.send({ type: "read", chatId: chat.id, seq: 2 });
    await readBy(sb, b.userId);
    expect((await msgRow(m1))!.delete_at).toBe(backstop);
    await setClock(t0 + 2000);
    sc.send({ type: "read", chatId: chat.id, seq: 1 });
    await readBy(sc, c.userId);
    expect((await msgRow(m1))!.delete_at).toBe(t0 + 2000 + WEEK_S * 1000);
    expect((await msgRow(m2))!.delete_at).toBe((await msgRow(m2))!.created_at + WEEK_S * 1000 + BACKSTOP_MS);
    expect(await alarmAt()).toBe(t0 + 2000 + WEEK_S * 1000);
    // Reading again later doesn't push it back.
    await setClock(t0 + 5000);
    sc.send({ type: "read", chatId: chat.id, seq: 1 });
    expect((await msgRow(m1))!.delete_at).toBe(t0 + 2000 + WEEK_S * 1000);

    await setClock(t0 + 2000 + WEEK_S * 1000);
    await runAlarm();
    for (const s of [sa, sb, sc]) expect(await s.next("gone")).toEqual({ type: "gone", chatId: chat.id, ids: [m1] });
    expect(await msgRow(m1)).toBeNull();
    expect((await history(b, chat.id)).map((m) => m.id)).toEqual([m2]);
    expect(await usage()).toBe(0);
    expect(await env.MEDIA.get(key)).toBeNull();
    expect((await download(a, key)).status).toBe(404);
    expect(await env.DB.prepare("SELECT COUNT(*) AS n FROM starred_messages").first("n")).toBe(0);
    expect(await remindersOf(c)).toEqual([]);
    expect(await alarmAt()).toBe((await msgRow(m2))!.delete_at);

    // A device that was offline learns of it from /me/gone; strangers learn nothing.
    const gone = await (await api(b.accessToken, "GET", "/me/gone?after=0")).json<{ gone: unknown[]; cursor: number }>();
    expect(gone.gone).toEqual([{ chatId: chat.id, messageId: m1, seq: 1 }]);
    expect((await (await api(b.accessToken, "GET", `/me/gone?after=${gone.cursor}`)).json<{ gone: unknown[]; cursor: number }>()))
      .toEqual({ gone: [], cursor: gone.cursor });
    expect((await (await api(stranger.accessToken, "GET", "/me/gone")).json<{ gone: unknown[] }>()).gone).toEqual([]);
    expect((await api(b.accessToken, "GET", "/me/gone?after=x")).status).toBe(400);
    // Tombstones are pruned once nobody can still hold the message.
    await setClock(t0 + 2000 + WEEK_S * 1000 + TOMBSTONE_KEEP_MS + 1);
    await runAlarm();
    // (m2 reached its backstop by then, so it is the one tombstone left.)
    const left = await env.DB.prepare("SELECT message_id FROM message_tombstones").all<{ message_id: string }>();
    expect(left.results.map((r) => r.message_id)).toEqual([m2]);
  });

  it("are deleted at the backstop when someone never reads them", async () => {
    const a = await insertUserWithDevice();
    const b = await insertUserWithDevice();
    const chat = await createGroup(a, [b]);
    await setTimer(a, chat.id, 86_400);
    const sa = await socket(a);
    const id = newId();
    sa.send({ type: "send", id, chatId: chat.id, envelope: envelope() });
    await sa.next("ack");
    const row = (await msgRow(id))!;
    await setClock(row.created_at + 86_400_000 + BACKSTOP_MS - 1);
    await runAlarm();
    expect(await msgRow(id)).not.toBeNull();
    await setClock(row.created_at + 86_400_000 + BACKSTOP_MS);
    await runAlarm();
    expect(await msgRow(id)).toBeNull();
    expect(await sa.next("gone")).toEqual({ type: "gone", chatId: chat.id, ids: [id] });
  });

  it("someone leaving no longer holds them back; history leaves out ones past their time", async () => {
    const a = await insertUserWithDevice();
    const b = await insertUserWithDevice();
    const c = await insertUserWithDevice();
    const chat = await createGroup(a, [b, c]);
    await setTimer(a, chat.id, 86_400);
    const sa = await socket(a);
    const sb = await socket(b);
    const id = newId();
    sa.send({ type: "send", id, chatId: chat.id, envelope: envelope() });
    await sa.next("ack");
    sb.send({ type: "read", chatId: chat.id, seq: 1 });
    await readBy(sb, b.userId);
    const before = (await msgRow(id))!.delete_at!;
    const t = Date.now();
    await api(c.accessToken, "DELETE", `/chats/${chat.id}/members/${c.userId}`);
    const after = (await msgRow(id))!.delete_at!;
    expect(after).toBeLessThan(before);
    expect(after).toBeGreaterThanOrEqual(t + 86_400_000);
    expect(await alarmAt()).toBe(after);
    // Past its time but not yet deleted by the hub: left out of history already.
    await env.DB.prepare("UPDATE messages SET delete_at = ? WHERE id = ?").bind(Date.now() - 1, id).run();
    expect(await history(a, chat.id)).toEqual([]);
  });

  it("in a chat with only the sender start their clock at once", async () => {
    const a = await insertUserWithDevice();
    const chat = await createGroup(a, []);
    await setTimer(a, chat.id, 86_400);
    const sa = await socket(a);
    const id = newId();
    sa.send({ type: "send", id, chatId: chat.id, envelope: envelope() });
    const ack = await sa.next("ack");
    expect((await msgRow(id))!.delete_at).toBe((ack.createdAt as number) + 86_400_000);
  });
});
