import { createExecutionContext, createMessageBatch, env, getQueueResult, SELF } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import type { PushJob } from "../src/hub";
import { deliverJob, handlePushBatch, sendAll } from "../src/push/consumer";
import { invalidateAccessToken, parseServiceAccount } from "../src/push/fcm";
import { addDevice, createDirect, createGroup, insertMessage } from "./chat-helpers";
import { BASE, insertUserWithDevice, jsonReq, resetDb } from "./helpers";
import { fakeGoogle, fcmError, testServiceAccount } from "./push-helpers";

const auth = (t: string) => ({ authorization: `Bearer ${t}` });
const setToken = (t: string, token: unknown) =>
  SELF.fetch(`${BASE}/api/devices/me/push`, jsonReq("PUT", { token }, auth(t)));
const tokenOf = async (deviceId: string) =>
  (await env.DB.prepare("SELECT push_token FROM devices WHERE id = ?").bind(deviceId).first<{ push_token: string | null }>())
    ?.push_token ?? null;

beforeEach(resetDb);

describe("PUT /api/devices/me/push", () => {
  it("stores, replaces and clears this device's token", async () => {
    const a = await insertUserWithDevice();
    expect((await setToken(a.accessToken, "tok-1")).status).toBe(204);
    expect(await tokenOf(a.deviceId)).toBe("tok-1");
    expect((await setToken(a.accessToken, "tok-2")).status).toBe(204);
    expect(await tokenOf(a.deviceId)).toBe("tok-2");
    expect((await setToken(a.accessToken, null)).status).toBe(204);
    expect(await tokenOf(a.deviceId)).toBeNull();
  });

  it("moves a token that another device row had", async () => {
    const a = await insertUserWithDevice();
    const b = await insertUserWithDevice();
    await setToken(a.accessToken, "shared");
    await setToken(b.accessToken, "shared");
    expect(await tokenOf(a.deviceId)).toBeNull();
    expect(await tokenOf(b.deviceId)).toBe("shared");
  });

  it("rejects bad bodies", async () => {
    const a = await insertUserWithDevice();
    for (const bad of [42, "", "x".repeat(4097), { t: 1 }]) {
      expect((await setToken(a.accessToken, bad)).status).toBe(400);
    }
    const res = await SELF.fetch(`${BASE}/api/devices/me/push`, { method: "PUT", headers: auth(a.accessToken), body: "nope" });
    expect(res.status).toBe(400);
  });

  it("requires auth", async () => {
    const res = await SELF.fetch(`${BASE}/api/devices/me/push`, jsonReq("PUT", { token: "x" }));
    expect(res.status).toBe(401);
  });
});

const setTok = (deviceId: string, tok: string | null) =>
  env.DB.prepare("UPDATE devices SET push_token = ? WHERE id = ?").bind(tok, deviceId).run();

async function family() {
  const mom = await insertUserWithDevice({ name: "Mom" });
  const dad = await insertUserWithDevice({ name: "Dad" });
  const kid = await insertUserWithDevice({ name: "Kid" });
  const dadLaptop = await addDevice(dad.userId);
  await setTok(dad.deviceId, "dad-phone");
  await setTok(dadLaptop, "dad-laptop");
  await setTok(kid.deviceId, "kid-phone");
  return { mom, dad, kid, dadLaptop };
}

function fakeQueue() {
  const sent: { job: PushJob; delaySeconds?: number }[] = [];
  const queue = {
    send: async (job: PushJob, o?: { delaySeconds?: number }) => void sent.push({ job, delaySeconds: o?.delaySeconds }),
  } as unknown as Queue<PushJob>;
  return { sent, queue };
}

async function pushEnv() {
  const q = fakeQueue();
  const json = (await testServiceAccount()).json;
  return { env: { ...env, FCM_SERVICE_ACCOUNT: json, PUSH_QUEUE: q.queue }, sa: parseServiceAccount(json), q };
}

const sentTokens = (g: ReturnType<typeof fakeGoogle>) =>
  g.sends().map((c) => (JSON.parse(c.body) as { message: { token: string } }).message.token).sort();

const jobBatch = (body: PushJob) =>
  createMessageBatch<PushJob>("famchat-push", [{ id: "m1", timestamp: new Date(), attempts: 1, body }]);

describe("push queue consumer", () => {
  beforeEach(() => invalidateAccessToken());

  it("sends a group message to every token of the offline members, names only", async () => {
    const { mom, dad, dadLaptop } = await family();
    const chat = await createGroup(mom, [dad], "Parents", [dadLaptop]);
    const id = await insertMessage(chat.id, mom);
    const { env: e } = await pushEnv();
    const g = fakeGoogle();
    const batch = jobBatch({ chatId: chat.id, senderUserId: mom.userId, messageId: id, userIds: [dad.userId] });
    const ctx = createExecutionContext();
    await handlePushBatch(batch, e, g.fetcher);
    expect((await getQueueResult(batch, ctx)).explicitAcks).toEqual(["m1"]);
    expect(sentTokens(g)).toEqual(["dad-laptop", "dad-phone"]);
    const stored = await env.DB.prepare("SELECT envelope FROM messages WHERE id = ?").bind(id).first<{ envelope: string }>();
    for (const s of g.sends()) {
      const m = (JSON.parse(s.body) as { message: Record<string, unknown> }).message;
      expect(m.notification).toEqual({ title: "Parents", body: "New message from Mom" });
      expect(m.data).toEqual({ chatId: chat.id });
      // Never the envelope, nor anything else from the message row.
      expect(s.body).not.toContain(stored!.envelope);
      expect(s.body).not.toContain('"ct"');
      expect(s.body).not.toContain('"nonce"');
      expect(s.body).not.toContain(id);
    }
  });

  it("a direct chat is titled with the sender's name", async () => {
    const { mom, kid } = await family();
    const chat = await createDirect(mom, kid);
    const { env: e, sa } = await pushEnv();
    const g = fakeGoogle();
    await deliverJob(e, sa, { chatId: chat.id, senderUserId: mom.userId, messageId: "m", userIds: [kid.userId] }, g.fetcher);
    const m = (JSON.parse(g.sends()[0].body) as { message: { notification: unknown } }).message;
    expect(m.notification).toEqual({ title: "Mom", body: "New message" });
  });

  it("skips users who are no longer members and revoked devices", async () => {
    const { mom, dad, kid, dadLaptop } = await family();
    const chat = await createGroup(mom, [dad], "Parents", [dadLaptop]);
    await env.DB.prepare("UPDATE devices SET revoked_at = 1 WHERE id = ?").bind(dadLaptop).run();
    const { env: e, sa } = await pushEnv();
    const g = fakeGoogle();
    await deliverJob(e, sa, { chatId: chat.id, senderUserId: mom.userId, messageId: "m", userIds: [dad.userId, kid.userId] }, g.fetcher);
    expect(sentTokens(g)).toEqual(["dad-phone"]);
  });

  it("stale tokens are cleared and the others still sent", async () => {
    const { mom, dad, dadLaptop } = await family();
    const chat = await createGroup(mom, [dad], "Family", [dadLaptop]);
    const { env: e, sa } = await pushEnv();
    const g = fakeGoogle((t) => (t === "dad-laptop" ? fcmError(404, "UNREGISTERED") : Response.json({ name: "x" })));
    const out = await deliverJob(e, sa, { chatId: chat.id, senderUserId: mom.userId, messageId: "m", userIds: [dad.userId] }, g.fetcher);
    expect(out.sort((x, y) => x.result.localeCompare(y.result))).toEqual([
      { deviceId: dad.deviceId, result: "ok" },
      { deviceId: dadLaptop, result: "stale" },
    ]);
    expect(await tokenOf(dadLaptop)).toBeNull();
    expect(await tokenOf(dad.deviceId)).toBe("dad-phone");
  });

  it("transient failures re-queue only the failed devices, up to three attempts", async () => {
    const { mom, dad, dadLaptop } = await family();
    const chat = await createGroup(mom, [dad], "Family", [dadLaptop]);
    const { env: e, sa, q } = await pushEnv();
    const g = fakeGoogle((t) => (t === "dad-laptop" ? fcmError(503, "UNAVAILABLE") : Response.json({ name: "x" })));
    const job = { chatId: chat.id, senderUserId: mom.userId, messageId: "m", userIds: [dad.userId] };
    await deliverJob(e, sa, job, g.fetcher);
    expect(q.sent).toEqual([{ job: { ...job, deviceIds: [dadLaptop], attempt: 1 }, delaySeconds: 10 }]);
    // The retry only goes to the laptop.
    const g2 = fakeGoogle(() => fcmError(503, "UNAVAILABLE"));
    await deliverJob(e, sa, q.sent[0].job, g2.fetcher);
    expect(sentTokens(g2)).toEqual(["dad-laptop"]);
    expect(q.sent[1]).toEqual({ job: { ...job, deviceIds: [dadLaptop], attempt: 2 }, delaySeconds: 20 });
    await deliverJob(e, sa, q.sent[1].job, g2.fetcher);
    expect(q.sent).toHaveLength(2); // gave up after the third try
  });

  it("a refused access token is renewed once", async () => {
    const { mom, dad, dadLaptop } = await family();
    await setTok(dadLaptop, null);
    const chat = await createGroup(mom, [dad], "Family", [dadLaptop]);
    const { env: e, sa } = await pushEnv();
    let first = true;
    const g = fakeGoogle(() => {
      if (!first) return Response.json({ name: "x" });
      first = false;
      return fcmError(401, "UNAUTHENTICATED");
    });
    const out = await deliverJob(e, sa, { chatId: chat.id, senderUserId: mom.userId, messageId: "m", userIds: [dad.userId] }, g.fetcher);
    expect(out).toEqual([{ deviceId: dad.deviceId, result: "ok" }]);
    expect(g.calls.filter((c) => c.url.includes("oauth2"))).toHaveLength(2);
    expect(g.sends().map((s) => s.headers.get("authorization"))).toEqual(["Bearer at-1", "Bearer at-2"]);
  });

  it("without FCM_SERVICE_ACCOUNT jobs are dropped without any request", async () => {
    const { mom, dad, dadLaptop } = await family();
    const chat = await createGroup(mom, [dad], "Family", [dadLaptop]);
    const g = fakeGoogle();
    const batch = jobBatch({ chatId: chat.id, senderUserId: mom.userId, messageId: "m", userIds: [dad.userId] });
    const ctx = createExecutionContext();
    await handlePushBatch(batch, { ...env, FCM_SERVICE_ACCOUNT: undefined }, g.fetcher);
    expect((await getQueueResult(batch, ctx)).ackAll).toBe(true);
    expect(g.calls).toEqual([]);
  });

  it("a job that throws is retried", async () => {
    const { mom, dad, dadLaptop } = await family();
    const chat = await createGroup(mom, [dad], "Family", [dadLaptop]);
    const { env: e } = await pushEnv();
    const batch = jobBatch({ chatId: chat.id, senderUserId: mom.userId, messageId: "m", userIds: [dad.userId] });
    const ctx = createExecutionContext();
    await handlePushBatch(batch, e, (async () => new Response("down", { status: 500 })) as typeof fetch);
    expect((await getQueueResult(batch, ctx)).retryMessages.map((m) => m.msgId)).toEqual(["m1"]);
  });
});

describe("POST /api/devices/me/push/test", () => {
  it("says push isn't configured without the secret", async () => {
    const a = await insertUserWithDevice();
    const res = await SELF.fetch(`${BASE}/api/devices/me/push/test`, { method: "POST", headers: auth(a.accessToken) });
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ configured: false, devices: [] });
  });

  it("sendAll reports each device", async () => {
    const { dad, dadLaptop } = await family();
    const { env: e, sa } = await pushEnv();
    const g = fakeGoogle((t) => (t === "dad-laptop" ? fcmError(404, "UNREGISTERED") : Response.json({ name: "x" })));
    const out = await sendAll(
      e,
      sa,
      [
        { id: dad.deviceId, push_token: "dad-phone" },
        { id: dadLaptop, push_token: "dad-laptop" },
      ],
      { title: "FamChat", body: "Test notification", chatId: null },
      g.fetcher,
    );
    expect(out).toEqual([{ deviceId: dad.deviceId, result: "ok" }, { deviceId: dadLaptop, result: "stale" }]);
    const m = (JSON.parse(g.sends()[0].body) as { message: Record<string, unknown> }).message;
    expect(m.data).toEqual({});
    expect(m.notification).toEqual({ title: "FamChat", body: "Test notification" });
  });

  it("requires auth", async () => {
    const res = await SELF.fetch(`${BASE}/api/devices/me/push/test`, { method: "POST" });
    expect(res.status).toBe(401);
  });
});
