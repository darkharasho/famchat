import { env, SELF } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { newId } from "../src/lib/ids";
import { claimMessage, recoveryKeyMessage, resetMessage } from "../src/lib/reset";
import { api, createDirect } from "./chat-helpers";
import { BASE, insertUserWithDevice, jsonReq, makeKeys, resetDb, type TestKeys } from "./helpers";
import { ed25519, registerRecovery, sign } from "./reset-helpers";
import { closeSockets, socket } from "./ws-helpers";

beforeEach(resetDb);
afterEach(closeSockets);

async function recoverBody(
  userId: string,
  oldIdentityPub: string,
  rk: { priv: CryptoKey; pub: string },
  opts: { keys?: TestKeys; resetId?: string; createdAt?: number } = {},
) {
  const k = opts.keys ?? (await makeKeys());
  const claim = await ed25519();
  const resetId = opts.resetId ?? newId();
  const createdAt = opts.createdAt ?? Date.now();
  const sig = await sign(rk.priv, resetMessage({
    resetId, userId, signerUserId: userId, signerKind: "recovery", oldIdentityPub, claimPub: claim.pub, createdAt,
  }));
  return {
    keys: k,
    body: {
      recoveryPub: rk.pub,
      resetId,
      oldIdentityPub,
      claimPub: claim.pub,
      createdAt,
      sig,
      claimSig: await sign(claim.priv, claimMessage(resetId, k.identityPub)),
      identityPub: k.identityPub,
      encPub: k.encPub,
      signPub: k.signPub,
      certSig: k.certSig,
      deviceName: "Recovered",
      platform: "web",
    },
  };
}

const recover = (body: unknown) => SELF.fetch(`${BASE}/api/auth/recover`, jsonReq("POST", body));

describe("POST /api/admin/recovery-key", () => {
  it("stores the key when the identity key signed it; /me shows it", async () => {
    const admin = await insertUserWithDevice({ admin: true });
    const me0 = await (await api(admin.accessToken, "GET", "/me")).json<{ recoveryCodeSet: boolean }>();
    expect(me0.recoveryCodeSet).toBe(false);
    const { res, rk } = await registerRecovery(admin);
    expect(res.status).toBe(204);
    const row = await env.DB.prepare("SELECT recovery_pub FROM users WHERE id = ?").bind(admin.userId).first<string>("recovery_pub");
    expect(row).toBe(rk.pub);
    const me = await (await api(admin.accessToken, "GET", "/me")).json<{ recoveryCodeSet: boolean }>();
    expect(me.recoveryCodeSet).toBe(true);
    expect(await env.DB.prepare("SELECT COUNT(*) AS n FROM events WHERE kind = 'recovery_key_set'").first<number>("n")).toBe(1);
  });

  it("bad signature -> 400; non-admin -> 403", async () => {
    const admin = await insertUserWithDevice({ admin: true });
    const rk = await ed25519();
    const other = await ed25519();
    const sig = await sign(other.priv, recoveryKeyMessage(admin.userId, rk.pub));
    expect((await api(admin.accessToken, "POST", "/admin/recovery-key", { recoveryPub: rk.pub, sig })).status).toBe(400);
    const member = await insertUserWithDevice();
    const msig = await sign(member.keys.identityPriv, recoveryKeyMessage(member.userId, rk.pub));
    expect((await api(member.accessToken, "POST", "/admin/recovery-key", { recoveryPub: rk.pub, sig: msig })).status).toBe(403);
  });
});

describe("POST /api/auth/recover", () => {
  it("recover with the code signs in, revokes old devices and clears the key", async () => {
    const admin = await insertUserWithDevice({ admin: true, name: "Michael" });
    const mom = await insertUserWithDevice({ name: "Mom" });
    const direct = await createDirect(admin, mom);
    const { rk } = await registerRecovery(admin);
    const momWs = await socket(mom);
    const { body, keys } = await recoverBody(admin.userId, admin.keys.identityPub, rk);
    const res = await recover(body);
    expect(res.status).toBe(201);
    const out = await res.json<{ userId: string; deviceId: string; isAdmin: boolean; accessToken: string; refreshToken: string }>();
    expect(out).toMatchObject({ userId: admin.userId, isAdmin: true });
    expect((await api(out.accessToken, "POST", "/admin/invites", { name: "X" })).status).toBe(201);
    expect((await api(admin.accessToken, "GET", "/me")).status).toBe(401);

    const { users } = await (await api(mom.accessToken, "GET", "/users")).json<{ users: { id: string; identityPub: string; resets: Record<string, unknown>[] }[] }>();
    const row = users.find((u) => u.id === admin.userId)!;
    expect(row.identityPub).toBe(keys.identityPub);
    expect(row.resets).toHaveLength(1);
    expect(row.resets[0]).toMatchObject({
      signerUserId: admin.userId,
      signerKind: "recovery",
      signerPub: rk.pub,
      oldIdentityPub: admin.keys.identityPub,
      newIdentityPub: keys.identityPub,
    });
    expect(row.resets[0].recoverySig).toBeTruthy();
    expect(await env.DB.prepare("SELECT recovery_pub FROM users WHERE id = ?").bind(admin.userId).first("recovery_pub")).toBeNull();
    expect((await api(out.accessToken, "GET", `/chats/${direct.id}`)).status).toBe(200);
    expect(await momWs.next("reset")).toMatchObject({ type: "reset", userId: admin.userId });
    expect(await env.DB.prepare("SELECT COUNT(*) AS n FROM events WHERE kind = 'recovered'").first<number>("n")).toBe(1);
  });

  it("recover retry within 10 min reissues tokens; used twice with new keys -> 401", async () => {
    const admin = await insertUserWithDevice({ admin: true });
    const { rk } = await registerRecovery(admin);
    const first = await recoverBody(admin.userId, admin.keys.identityPub, rk);
    const a = await (await recover(first.body)).json<{ deviceId: string }>();
    const again = await recover(first.body);
    expect(again.status).toBe(201);
    expect(await again.json()).toMatchObject({ userId: admin.userId, deviceId: a.deviceId });
    const other = await recoverBody(admin.userId, first.keys.identityPub, rk);
    expect((await recover(other.body)).status).toBe(401);
  });

  it("recover with an unknown key -> 401", async () => {
    const admin = await insertUserWithDevice({ admin: true });
    await registerRecovery(admin);
    const stranger = await ed25519();
    const { body } = await recoverBody(admin.userId, admin.keys.identityPub, stranger);
    expect((await recover(body)).status).toBe(401);
  });

  it("bad statement signature, stale key or bad claim -> refused", async () => {
    const admin = await insertUserWithDevice({ admin: true });
    const { rk } = await registerRecovery(admin);
    const ok = await recoverBody(admin.userId, admin.keys.identityPub, rk);
    expect((await recover({ ...ok.body, sig: ok.body.claimSig })).status).toBe(400);
    expect((await recover({ ...ok.body, claimSig: ok.body.sig })).status).toBe(400);
    const stale = await recoverBody(admin.userId, (await makeKeys()).identityPub, rk);
    expect((await recover(stale.body)).status).toBe(409);
    const old = await recoverBody(admin.userId, admin.keys.identityPub, rk, { createdAt: Date.now() - 3_600_000 });
    expect((await recover(old.body)).status).toBe(400);
    // Still usable after the failures.
    expect((await recover(ok.body)).status).toBe(201);
  });
});
