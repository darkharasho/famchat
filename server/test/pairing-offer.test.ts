// Reverse pairing: a signed-in device shows an offer code, the new device starts its session with it.
import { env, SELF } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { b64urlEncode } from "../src/lib/encoding";
import { MAX_OFFERS_PER_USER, PAIR_TTL_MS } from "../src/routes/pairing";
import { api, type TestUser } from "./chat-helpers";
import { BASE, certMessage, insertUserWithDevice, jsonReq, makeKeys, resetDb, type TestKeys } from "./helpers";

type Offer = { offerId: string; code: string; expiresAt: number; expiresIn: number };
type Start = { sessionId: string; code: string; secret: string; deviceId: string };
type SessionOut = {
  code: string;
  deviceId: string;
  ephPub: string;
  encPub: string;
  signPub: string;
  keysMac: string;
  deviceName: string;
  platform: string;
  expiresAt: number;
};

const rand = (n: number) => b64urlEncode(crypto.getRandomValues(new Uint8Array(n)));

async function offer(user: TestUser): Promise<Offer> {
  const res = await api(user.accessToken, "POST", "/devices/pair/offer");
  expect(res.status).toBe(201);
  return res.json<Offer>();
}

const poll = (user: TestUser, offerId: string) => api(user.accessToken, "GET", `/devices/pair/offer/${offerId}`);
const cancelOffer = (user: TestUser, offerId: string) => api(user.accessToken, "POST", `/devices/pair/offer/${offerId}/cancel`);

function start(keys: TestKeys, offerCode: unknown, ip = "203.0.113.7") {
  return SELF.fetch(
    `${BASE}/api/devices/pair/start`,
    jsonReq(
      "POST",
      {
        ephPub: rand(32),
        encPub: keys.encPub,
        signPub: keys.signPub,
        keysMac: rand(32),
        deviceName: "New phone",
        platform: "ios",
        offer: offerCode,
      },
      { "cf-connecting-ip": ip },
    ),
  );
}

async function startOk(offerCode: string, ip?: string): Promise<Start & { keys: TestKeys }> {
  const keys = await makeKeys();
  const res = await start(keys, offerCode, ip);
  expect(res.status).toBe(201);
  return { ...(await res.json<Start>()), keys };
}

async function certFor(approver: TestUser, keys: TestKeys): Promise<string> {
  const sig = await crypto.subtle.sign("Ed25519", approver.keys.identityPriv, certMessage(keys.raw.encPub, keys.raw.signPub));
  return b64urlEncode(new Uint8Array(sig));
}

const claim = (sessionId: string, secret: string) =>
  SELF.fetch(`${BASE}/api/devices/pair/claim`, jsonReq("POST", { sessionId, secret }));

async function ageOffer(offerId: string, ms: number) {
  await env.DB.prepare("UPDATE pair_offers SET created_at = created_at - ?, expires_at = expires_at - ? WHERE id = ?")
    .bind(ms, ms, offerId).run();
}

beforeEach(resetDb);

describe("POST /api/devices/pair/offer", () => {
  it("needs auth", async () => {
    const res = await SELF.fetch(`${BASE}/api/devices/pair/offer`, jsonReq("POST", {}));
    expect(res.status).toBe(401);
  });

  it("returns an offer id and a lookup code", async () => {
    const alice = await insertUserWithDevice();
    const o = await offer(alice);
    expect(o.code).toMatch(/^[0-9A-HJKMNP-TV-Z]{4}$/);
    expect(o.offerId).toMatch(/^[0-9A-HJKMNP-TV-Z]{26}$/);
    expect(o.expiresIn).toBe(PAIR_TTL_MS);
    expect(o.expiresAt).toBeGreaterThan(Date.now());
  });

  it("is rate limited per user", async () => {
    const alice = await insertUserWithDevice();
    const bob = await insertUserWithDevice();
    for (let i = 0; i < MAX_OFFERS_PER_USER; i++) await offer(alice);
    const res = await api(alice.accessToken, "POST", "/devices/pair/offer");
    expect(res.status).toBe(429);
    await offer(bob);
  });
});

describe("reverse pairing", () => {
  it("happy path: offer, start with it, poll, approve, claim", async () => {
    const alice = await insertUserWithDevice();
    const o = await offer(alice);

    const waiting = await poll(alice, o.offerId);
    expect(waiting.status).toBe(200);
    expect(await waiting.json()).toEqual({ status: "waiting", expiresAt: o.expiresAt });

    const n = await startOk(o.code.toLowerCase());
    const ready = await poll(alice, o.offerId);
    expect(ready.status).toBe(200);
    const body = await ready.json<{ status: string; session: SessionOut }>();
    expect(body.status).toBe("ready");
    expect(body.session).toMatchObject({
      code: n.code,
      deviceId: n.deviceId,
      encPub: n.keys.encPub,
      signPub: n.keys.signPub,
      deviceName: "New phone",
      platform: "ios",
    });

    const approve = await api(alice.accessToken, "POST", `/devices/pair/${body.session.code}/approve`, {
      deviceId: n.deviceId,
      certSig: await certFor(alice, n.keys),
      bundle: rand(200),
    });
    expect(approve.status).toBe(204);
    expect(await (await poll(alice, o.offerId)).json()).toEqual({ status: "approved" });

    const c = await claim(n.sessionId, n.secret);
    expect(c.status).toBe(200);
    expect(await c.json()).toMatchObject({ status: "approved", userId: alice.userId, deviceId: n.deviceId });
  });

  it("an offer is single use", async () => {
    const alice = await insertUserWithDevice();
    const o = await offer(alice);
    await startOk(o.code);
    const res = await start(await makeKeys(), o.code);
    expect(res.status).toBe(404);
  });

  it("an unknown offer code is refused and counts against the network's start limit", async () => {
    const k = await makeKeys();
    for (let i = 0; i < 5; i++) expect((await start(k, "ZZZZ", "198.51.100.3")).status).toBe(404);
    expect((await start(k, "ZZZZ", "198.51.100.3")).status).toBe(429);
  });

  it("a malformed offer code is a bad request", async () => {
    const k = await makeKeys();
    for (const bad of ["", "ABC", "ABCDE", "AB!D", 42]) {
      expect((await start(k, bad)).status, JSON.stringify(bad)).toBe(400);
    }
  });

  it("an expired offer can't be taken and polls as gone", async () => {
    const alice = await insertUserWithDevice();
    const o = await offer(alice);
    await ageOffer(o.offerId, PAIR_TTL_MS + 1000);
    expect((await start(await makeKeys(), o.code)).status).toBe(404);
    const res = await poll(alice, o.offerId);
    expect(res.status).toBe(410);
    expect(await res.json()).toEqual({ error: "pairing_invalid" });
  });

  it("another user can't see or use the offer or its session", async () => {
    const alice = await insertUserWithDevice();
    const bob = await insertUserWithDevice();
    const o = await offer(alice);
    const n = await startOk(o.code);
    expect((await poll(bob, o.offerId)).status).toBe(404);
    expect((await cancelOffer(bob, o.offerId)).status).toBe(404);
    expect((await api(bob.accessToken, "GET", `/devices/pair/${n.code}`)).status).toBe(404);
    const approve = await api(bob.accessToken, "POST", `/devices/pair/${n.code}/approve`, {
      deviceId: n.deviceId,
      certSig: await certFor(bob, n.keys),
      bundle: rand(200),
    });
    expect(approve.status).toBe(404);
    // Alice still can.
    expect((await api(alice.accessToken, "GET", `/devices/pair/${n.code}`)).status).toBe(200);
  });

  it("poll needs auth", async () => {
    const alice = await insertUserWithDevice();
    const o = await offer(alice);
    expect((await SELF.fetch(`${BASE}/api/devices/pair/offer/${o.offerId}`)).status).toBe(401);
  });

  it("a cancelled offer can't be taken", async () => {
    const alice = await insertUserWithDevice();
    const o = await offer(alice);
    expect((await cancelOffer(alice, o.offerId)).status).toBe(204);
    expect((await start(await makeKeys(), o.code)).status).toBe(404);
    expect((await poll(alice, o.offerId)).status).toBe(410);
  });

  it("cancelling a taken offer cancels the new device's session", async () => {
    const alice = await insertUserWithDevice();
    const o = await offer(alice);
    const n = await startOk(o.code);
    expect((await cancelOffer(alice, o.offerId)).status).toBe(204);
    expect((await claim(n.sessionId, n.secret)).status).toBe(410);
    expect((await api(alice.accessToken, "GET", `/devices/pair/${n.code}`)).status).toBe(404);
  });

  it("the new device cancelling ends the offer", async () => {
    const alice = await insertUserWithDevice();
    const o = await offer(alice);
    const n = await startOk(o.code);
    const res = await SELF.fetch(`${BASE}/api/devices/pair/cancel`, jsonReq("POST", { sessionId: n.sessionId, secret: n.secret }));
    expect(res.status).toBe(204);
    expect((await poll(alice, o.offerId)).status).toBe(410);
  });

  it("an expired session polls as gone", async () => {
    const alice = await insertUserWithDevice();
    const o = await offer(alice);
    const n = await startOk(o.code);
    await env.DB.prepare("UPDATE pair_sessions SET expires_at = ? WHERE id = ?").bind(Date.now() - 1, n.sessionId).run();
    expect((await poll(alice, o.offerId)).status).toBe(410);
  });

  it("unknown offer id -> 404", async () => {
    const alice = await insertUserWithDevice();
    expect((await poll(alice, "01JUNKNOWN0000000000000000")).status).toBe(404);
    expect((await cancelOffer(alice, "01JUNKNOWN0000000000000000")).status).toBe(404);
  });
});
