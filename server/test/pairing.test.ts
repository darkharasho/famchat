import { env, SELF } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { b64urlEncode } from "../src/lib/encoding";
import { CLAIM_RETRY_MS, ipKey, PAIR_TTL_MS } from "../src/routes/pairing";
import { addDevice, api, createDirect, type TestUser } from "./chat-helpers";
import { closeSockets, socket } from "./ws-helpers";
import { BASE, certMessage, insertUserWithDevice, jsonReq, makeKeys, resetDb, type TestKeys } from "./helpers";

type Start = { sessionId: string; code: string; secret: string; deviceId: string; expiresAt: number; expiresIn: number };
type Approved = {
  status: "approved";
  userId: string;
  deviceId: string;
  isAdmin: boolean;
  accessToken: string;
  refreshToken: string;
  bundle: string;
};

const rand = (n: number) => b64urlEncode(crypto.getRandomValues(new Uint8Array(n)));

function startBody(keys: TestKeys, over: Record<string, unknown> = {}) {
  return {
    ephPub: rand(32),
    encPub: keys.encPub,
    signPub: keys.signPub,
    keysMac: rand(32),
    deviceName: "New laptop",
    platform: "linux",
    ...over,
  };
}

function start(body: unknown, ip = "203.0.113.7") {
  return SELF.fetch(`${BASE}/api/devices/pair/start`, jsonReq("POST", body, { "cf-connecting-ip": ip }));
}

async function startOk(keys?: TestKeys): Promise<Start & { keys: TestKeys }> {
  const k = keys ?? (await makeKeys());
  const res = await start(startBody(k));
  expect(res.status).toBe(201);
  return { ...(await res.json<Start>()), keys: k };
}

/** The approving user's identity key signs the new device's keys. */
async function certFor(approver: TestUser, keys: TestKeys): Promise<string> {
  const sig = await crypto.subtle.sign("Ed25519", approver.keys.identityPriv, certMessage(keys.raw.encPub, keys.raw.signPub));
  return b64urlEncode(new Uint8Array(sig));
}

async function approve(approver: TestUser, s: Start & { keys: TestKeys }, over: Record<string, unknown> = {}) {
  return api(approver.accessToken, "POST", `/devices/pair/${s.code}/approve`, {
    deviceId: s.deviceId,
    certSig: await certFor(approver, s.keys),
    bundle: rand(200),
    ...over,
  });
}

const claim = (sessionId: string, secret: string) =>
  SELF.fetch(`${BASE}/api/devices/pair/claim`, jsonReq("POST", { sessionId, secret }));

const cancel = (sessionId: string, secret: string) =>
  SELF.fetch(`${BASE}/api/devices/pair/cancel`, jsonReq("POST", { sessionId, secret }));

/** Moves a session's clock back by [ms] (as if it was started that long ago). */
async function age(sessionId: string, ms: number) {
  await env.DB.prepare(
    `UPDATE pair_sessions SET created_at = created_at - ?, expires_at = expires_at - ?,
       approved_at = approved_at - ?, claimed_at = claimed_at - ? WHERE id = ?`,
  ).bind(ms, ms, ms, ms, sessionId).run();
}

afterEach(closeSockets);
beforeEach(resetDb);

describe("POST /api/devices/pair/start", () => {
  it("needs no auth and returns a code", async () => {
    const s = await startOk();
    expect(s.code).toMatch(/^[0-9A-HJKMNP-TV-Z]{4}$/);
    expect(s.sessionId).toMatch(/^[0-9A-HJKMNP-TV-Z]{26}$/);
    expect(s.deviceId).toMatch(/^[0-9A-HJKMNP-TV-Z]{26}$/);
    expect(s.secret.length).toBeGreaterThanOrEqual(43);
    expect(s.expiresIn).toBe(PAIR_TTL_MS);
    expect(s.expiresAt).toBeGreaterThan(Date.now());
  });

  it("validates keys, mac, name and platform", async () => {
    const k = await makeKeys();
    for (const over of [
      { ephPub: rand(31) },
      { encPub: "!!" },
      { signPub: rand(33) },
      { keysMac: rand(16) },
      { deviceName: "  " },
      { deviceName: "x".repeat(61) },
      { platform: "beos" },
    ]) {
      const res = await start(startBody(k, over));
      expect(res.status, JSON.stringify(over)).toBe(400);
    }
  });

  it("is rate limited per IP", async () => {
    const k = await makeKeys();
    for (let i = 0; i < 5; i++) expect((await start(startBody(k), "198.51.100.1")).status).toBe(201);
    const res = await start(startBody(k), "198.51.100.1");
    expect(res.status).toBe(429);
    expect(await res.json()).toEqual({ error: "rate_limited" });
    expect((await start(startBody(k), "198.51.100.2")).status).toBe(201);
  });
});

describe("ipKey", () => {
  it("keys IPv6 by /64 and IPv4 as is", () => {
    expect(ipKey("2001:db8:1:2:aaaa::1")).toBe("2001:db8:1:2::/64");
    expect(ipKey("2001:0db8:0001:0002:ffff:ffff:ffff:ffff")).toBe("2001:db8:1:2::/64");
    expect(ipKey("2001:db8::5")).toBe("2001:db8:0:0::/64");
    expect(ipKey("::1")).toBe("0:0:0:0::/64");
    expect(ipKey("203.0.113.9")).toBe("203.0.113.9");
    expect(ipKey(null)).toBeNull();
  });

  it("addresses in one IPv6 /64 share the start limit", async () => {
    const k = await makeKeys();
    for (let i = 0; i < 5; i++) expect((await start(startBody(k), `2001:db8:7:7::${i + 1}`)).status).toBe(201);
    expect((await start(startBody(k), "2001:db8:7:7:ffff::9")).status).toBe(429);
    expect((await start(startBody(k), "2001:db8:7:8::1")).status).toBe(201);
  });
});

describe("pairing", () => {
  it("happy path: lookup, approve, claim gives working tokens and the bundle", async () => {
    const alice = await insertUserWithDevice({ name: "Alice" });
    const s = await startOk();

    const look = await api(alice.accessToken, "GET", `/devices/pair/${s.code}`);
    expect(look.status).toBe(200);
    const { session } = await look.json<{ session: Record<string, unknown> }>();
    expect(session).toMatchObject({
      code: s.code,
      deviceId: s.deviceId,
      encPub: s.keys.encPub,
      signPub: s.keys.signPub,
      deviceName: "New laptop",
      platform: "linux",
    });
    expect(typeof session.ephPub).toBe("string");
    expect(typeof session.keysMac).toBe("string");

    const bundle = rand(300);
    expect((await approve(alice, s, { bundle })).status).toBe(204);

    const res = await claim(s.sessionId, s.secret);
    expect(res.status).toBe(200);
    const body = await res.json<Approved>();
    expect(body).toMatchObject({ status: "approved", userId: alice.userId, deviceId: s.deviceId, isAdmin: false, bundle });

    const me = await api(body.accessToken, "GET", "/me");
    expect(me.status).toBe(200);
    expect(await me.json()).toMatchObject({ userId: alice.userId, deviceId: s.deviceId });

    const { users } = await (await api(alice.accessToken, "GET", "/users")).json<{
      users: { id: string; devices: { id: string; encPub: string; signPub: string; certSig: string; name: string; platform: string }[] }[];
    }>();
    const dev = users.find((u) => u.id === alice.userId)!.devices.find((d) => d.id === s.deviceId)!;
    expect(dev).toMatchObject({ encPub: s.keys.encPub, signPub: s.keys.signPub, name: "New laptop", platform: "linux" });
    expect(dev.certSig).toBe(await certFor(alice, s.keys)); // Ed25519 is deterministic

    const refreshed = await SELF.fetch(`${BASE}/api/auth/refresh`, jsonReq("POST", { refreshToken: body.refreshToken }));
    expect(refreshed.status).toBe(200);
  });

  it("claim before approval waits", async () => {
    const s = await startOk();
    const res = await claim(s.sessionId, s.secret);
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ status: "waiting" });
  });

  it("approve is single use", async () => {
    const alice = await insertUserWithDevice();
    const s = await startOk();
    expect((await approve(alice, s)).status).toBe(204);
    expect((await approve(alice, s)).status).toBe(404);
    expect((await api(alice.accessToken, "GET", `/devices/pair/${s.code}`)).status).toBe(404);
  });

  it("repeat claim reissues tokens", async () => {
    const alice = await insertUserWithDevice();
    const s = await startOk();
    await approve(alice, s);
    const first = await (await claim(s.sessionId, s.secret)).json<Approved>();
    const second = await claim(s.sessionId, s.secret);
    expect(second.status).toBe(200);
    const again = await second.json<Approved>();
    expect(again.deviceId).toBe(first.deviceId);
    expect(again.refreshToken).not.toBe(first.refreshToken);
    const n = await env.DB.prepare("SELECT COUNT(*) AS n FROM devices WHERE id = ?").bind(s.deviceId).first<number>("n");
    expect(n).toBe(1);
    const old = await SELF.fetch(`${BASE}/api/auth/refresh`, jsonReq("POST", { refreshToken: first.refreshToken }));
    expect(old.status).toBe(401);
    const fresh = await SELF.fetch(`${BASE}/api/auth/refresh`, jsonReq("POST", { refreshToken: again.refreshToken }));
    expect(fresh.status).toBe(200);
  });

  it("claim is single use after the retry window", async () => {
    const alice = await insertUserWithDevice();
    const s = await startOk();
    await approve(alice, s);
    expect((await claim(s.sessionId, s.secret)).status).toBe(200);
    await age(s.sessionId, CLAIM_RETRY_MS + 1000);
    const res = await claim(s.sessionId, s.secret);
    expect(res.status).toBe(410);
    expect(await res.json()).toEqual({ error: "pairing_invalid" });
  });

  it("a repeat claim for a revoked device is refused", async () => {
    const alice = await insertUserWithDevice();
    const s = await startOk();
    await approve(alice, s);
    await claim(s.sessionId, s.secret);
    expect((await api(alice.accessToken, "DELETE", `/devices/${s.deviceId}`)).status).toBe(204);
    expect((await claim(s.sessionId, s.secret)).status).toBe(410);
  });

  it("wrong secret or unknown session -> 404", async () => {
    const alice = await insertUserWithDevice();
    const s = await startOk();
    await approve(alice, s);
    expect((await claim(s.sessionId, rand(32))).status).toBe(404);
    expect((await claim("01JUNKNOWN0000000000000000", s.secret)).status).toBe(404);
    expect((await cancel(s.sessionId, rand(32))).status).toBe(404);
  });

  it("expired session: lookup 404, approve 404, claim 410", async () => {
    const alice = await insertUserWithDevice();
    const s = await startOk();
    await age(s.sessionId, PAIR_TTL_MS + 1000);
    expect((await api(alice.accessToken, "GET", `/devices/pair/${s.code}`)).status).toBe(404);
    expect((await approve(alice, s)).status).toBe(404);
    expect((await claim(s.sessionId, s.secret)).status).toBe(410);
  });

  it("approved but never claimed in time -> 410", async () => {
    const alice = await insertUserWithDevice();
    const s = await startOk();
    await approve(alice, s);
    await age(s.sessionId, CLAIM_RETRY_MS + 1000);
    expect((await claim(s.sessionId, s.secret)).status).toBe(410);
    const n = await env.DB.prepare("SELECT COUNT(*) AS n FROM devices WHERE id = ?").bind(s.deviceId).first<number>("n");
    expect(n).toBe(0);
  });

  it("approval cert signed by another user's identity -> 400", async () => {
    const alice = await insertUserWithDevice();
    const bob = await insertUserWithDevice();
    const s = await startOk();
    const res = await approve(alice, s, { certSig: await certFor(bob, s.keys) });
    expect(res.status).toBe(400);
    // Still pending: the right user can approve.
    expect((await approve(alice, s)).status).toBe(204);
  });

  it("approval must name the session's device id", async () => {
    const alice = await insertUserWithDevice();
    const s = await startOk();
    expect((await approve(alice, s, { deviceId: "01JOTHER00000000000000000X" })).status).toBe(400);
  });

  it("approval needs auth", async () => {
    const s = await startOk();
    const res = await SELF.fetch(`${BASE}/api/devices/pair/${s.code}`);
    expect(res.status).toBe(401);
  });

  it("revoking the approving device voids its unclaimed approval", async () => {
    const alice = await insertUserWithDevice();
    const laptop = await addDevice(alice.userId);
    const s = await startOk();
    // The approval comes from Alice's (stolen) laptop; Alice then revokes the laptop from her phone.
    await env.DB.prepare(
      `UPDATE pair_sessions SET user_id = ?, approved_by_device = ?, approved_at = ?, cert_sig = ?, bundle = ? WHERE id = ?`,
    ).bind(alice.userId, laptop, Date.now(), await certFor(alice, s.keys), rand(200), s.sessionId).run();
    expect((await api(alice.accessToken, "DELETE", `/devices/${laptop}`)).status).toBe(204);
    const res = await claim(s.sessionId, s.secret);
    expect(res.status).toBe(410);
    const n = await env.DB.prepare("SELECT COUNT(*) AS n FROM devices WHERE id = ?").bind(s.deviceId).first<number>("n");
    expect(n).toBe(0);
  });

  it("a claim needs the approving device to still be live", async () => {
    const alice = await insertUserWithDevice();
    const s = await startOk();
    await approve(alice, s);
    // Revoked by some path that didn't cancel the session (e.g. the refresh-reuse rule).
    await env.DB.prepare("UPDATE devices SET revoked_at = 1 WHERE id = ?").bind(alice.deviceId).run();
    expect((await claim(s.sessionId, s.secret)).status).toBe(410);
  });

  it("approve needs auth", async () => {
    const s = await startOk();
    const res = await SELF.fetch(`${BASE}/api/devices/pair/${s.code}/approve`, jsonReq("POST", { deviceId: s.deviceId, certSig: rand(64), bundle: rand(200) }));
    expect(res.status).toBe(401);
  });

  it("cancelled session cannot be approved or claimed", async () => {
    const alice = await insertUserWithDevice();
    const s = await startOk();
    expect((await cancel(s.sessionId, s.secret)).status).toBe(204);
    expect((await approve(alice, s)).status).toBe(404);
    expect((await claim(s.sessionId, s.secret)).status).toBe(410);
  });

  it("claim notifies sharing users with a device event", async () => {
    const alice = await insertUserWithDevice({ name: "Alice" });
    const bob = await insertUserWithDevice({ name: "Bob" });
    const carol = await insertUserWithDevice({ name: "Carol" });
    await createDirect(alice, bob);
    const bobWs = await socket(bob);
    const carolWs = await socket(carol);
    const s = await startOk();
    await approve(alice, s);
    await claim(s.sessionId, s.secret);
    expect(await bobWs.next("device")).toEqual({ type: "device", userId: alice.userId, deviceId: s.deviceId });
    await carolWs.none("device");
  });
});
