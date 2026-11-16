import { env, SELF } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { promotionMessage } from "../src/lib/reset";
import { resetAccount } from "../src/lib/reset-account";
import { addDevice, api, createDirect, createGroup, type ChatOut, type TestUser } from "./chat-helpers";
import { BASE, insertUserWithDevice, jsonReq, makeKeys, resetDb } from "./helpers";
import { ed25519, postReset, redeemReset, resetUser, sign, signedReset } from "./reset-helpers";
import { closeSockets, socket } from "./ws-helpers";

beforeEach(resetDb);
afterEach(closeSockets);

type UserOut = {
  id: string;
  isAdmin: boolean;
  identityPub: string;
  adminProof: { byUserId: string; signerPub: string; sig: string } | null;
  devices: { id: string; revoked: boolean }[];
  resets: {
    id: string;
    signerUserId: string;
    signerKind: string;
    signerPub: string;
    oldIdentityPub: string;
    claimPub: string;
    createdAt: number;
    sig: string;
    newIdentityPub: string | null;
    claimSig: string | null;
    completedAt: number | null;
  }[];
};

const users = async (token: string) => (await (await api(token, "GET", "/users")).json<{ users: UserOut[] }>()).users;
const getChat = async (token: string, id: string) =>
  (await (await api(token, "GET", `/chats/${id}`)).json<{ chat: ChatOut }>()).chat;

describe("POST /api/admin/users/:id/reset", () => {
  it("non-admin -> 403", async () => {
    const member = await insertUserWithDevice();
    const mom = await insertUserWithDevice({ name: "Mom" });
    const r = await signedReset(member, { userId: mom.userId, identityPub: mom.keys.identityPub });
    const res = await postReset(member, mom.userId, r.body);
    expect(res.status).toBe(403);
  });

  it("an admin can't reset themselves", async () => {
    const admin = await insertUserWithDevice({ admin: true });
    const r = await signedReset(admin, { userId: admin.userId, identityPub: admin.keys.identityPub });
    expect((await postReset(admin, admin.userId, r.body)).status).toBe(400);
  });

  it("unknown user -> 404", async () => {
    const admin = await insertUserWithDevice({ admin: true });
    const r = await signedReset(admin, { userId: "01JNOPE0000000000000000000", identityPub: admin.keys.identityPub });
    expect((await postReset(admin, "01JNOPE0000000000000000000", r.body)).status).toBe(404);
  });

  it("reset signature from another key -> 400", async () => {
    const admin = await insertUserWithDevice({ admin: true });
    const mom = await insertUserWithDevice({ name: "Mom" });
    const other = await ed25519();
    const r = await signedReset(admin, { userId: mom.userId, identityPub: mom.keys.identityPub }, {}, other.priv);
    expect((await postReset(admin, mom.userId, r.body)).status).toBe(400);
    const live = await env.DB.prepare("SELECT COUNT(*) AS n FROM devices WHERE user_id = ? AND revoked_at IS NULL")
      .bind(mom.userId).first<number>("n");
    expect(live).toBe(1);
  });

  it("a statement for another user does not verify", async () => {
    const admin = await insertUserWithDevice({ admin: true });
    const mom = await insertUserWithDevice({ name: "Mom" });
    const dad = await insertUserWithDevice({ name: "Dad" });
    const r = await signedReset(admin, { userId: dad.userId, identityPub: mom.keys.identityPub });
    expect((await postReset(admin, mom.userId, r.body)).status).toBe(400);
  });

  it("stale old identity key -> 409", async () => {
    const admin = await insertUserWithDevice({ admin: true });
    const mom = await insertUserWithDevice({ name: "Mom" });
    const r = await signedReset(admin, { userId: mom.userId, identityPub: (await makeKeys()).identityPub });
    const res = await postReset(admin, mom.userId, r.body);
    expect(res.status).toBe(409);
    expect(await res.json()).toEqual({ error: "conflict" });
  });

  it("a signed time far from now -> 400", async () => {
    const admin = await insertUserWithDevice({ admin: true });
    const mom = await insertUserWithDevice({ name: "Mom" });
    const r = await signedReset(admin, { userId: mom.userId, identityPub: mom.keys.identityPub }, { createdAt: Date.now() - 3_600_000 });
    expect((await postReset(admin, mom.userId, r.body)).status).toBe(400);
  });

  it("malformed body -> 400", async () => {
    const admin = await insertUserWithDevice({ admin: true });
    const mom = await insertUserWithDevice({ name: "Mom" });
    const r = await signedReset(admin, { userId: mom.userId, identityPub: mom.keys.identityPub });
    expect((await postReset(admin, mom.userId, { ...r.body, resetId: "nope" })).status).toBe(400);
    expect((await postReset(admin, mom.userId, { ...r.body, claimPub: "AAAA" })).status).toBe(400);
    expect((await postReset(admin, mom.userId, { ...r.body, sig: undefined })).status).toBe(400);
  });

  it("reset revokes devices, rotates chats, cancels pairings and returns a link", async () => {
    const admin = await insertUserWithDevice({ admin: true, name: "Michael" });
    const mom = await insertUserWithDevice({ name: "Mom" });
    const bob = await insertUserWithDevice({ name: "Bob" });
    const direct = await createDirect(admin, mom);
    const tablet = await addDevice(mom.userId);
    const group = await createGroup(bob, [mom], "Family", [tablet]);
    await env.DB.prepare(
      `INSERT INTO pair_sessions (id, code, secret_hash, device_id, eph_pub, enc_pub, sign_pub, keys_mac, device_name,
         platform, created_at, expires_at, user_id, approved_by_device, approved_at, cert_sig, bundle)
       VALUES ('S1', 'ABCD', 'h', 'D1', 'e', 'e', 's', 'm', 'Laptop', 'linux', 1, ?, ?, ?, ?, 'c', 'b')`,
    ).bind(Date.now() + 60_000, mom.userId, mom.deviceId, Date.now()).run();

    const out = await resetUser(admin, mom);
    expect(out.inviteUrl).toBe(`https://famchat.dev/join#${out.inviteToken}`);
    expect(out.resetId).toBe(out.statement.resetId);

    const momRow = (await users(admin.accessToken)).find((u) => u.id === mom.userId)!;
    expect(momRow.devices.every((d) => d.revoked)).toBe(true);
    expect(momRow.identityPub).toBe(mom.keys.identityPub); // unchanged until the link is used
    expect(momRow.resets).toHaveLength(1);
    expect(momRow.resets[0]).toMatchObject({
      id: out.resetId,
      signerUserId: admin.userId,
      signerKind: "admin",
      signerPub: admin.keys.identityPub,
      oldIdentityPub: mom.keys.identityPub,
      claimPub: out.claim.pub,
      newIdentityPub: null,
      completedAt: null,
    });
    for (const [token, id] of [[admin.accessToken, direct.id], [bob.accessToken, group.id]]) {
      const c = await getChat(token, id);
      expect(c.currentEpoch).toBe(2);
      expect(c.epochReady).toBe(false);
    }
    const cancelled = await env.DB.prepare("SELECT cancelled_at FROM pair_sessions WHERE id = 'S1'").first<number | null>("cancelled_at");
    expect(cancelled).not.toBeNull();
    // Mom's old token stops working.
    expect((await api(mom.accessToken, "GET", "/me")).status).toBe(401);
    const ev = await env.DB.prepare("SELECT kind, user_id, actor_id, payload FROM events WHERE kind = 'reset'").first<Record<string, string>>();
    expect(ev).toMatchObject({ kind: "reset", user_id: mom.userId, actor_id: admin.userId });
    expect(JSON.parse(ev!.payload)).toMatchObject({ resetId: out.resetId });
  });

  it("notifies the family: reset, device and chat events, and closes old sockets", async () => {
    const admin = await insertUserWithDevice({ admin: true });
    const mom = await insertUserWithDevice({ name: "Mom" });
    const carol = await insertUserWithDevice({ name: "Carol" }); // shares no chat with Mom
    const direct = await createDirect(admin, mom);
    const adminWs = await socket(admin);
    const carolWs = await socket(carol);
    const momWs = await socket(mom);
    const out = await resetUser(admin, mom);
    expect(await adminWs.next("reset")).toEqual({ type: "reset", userId: mom.userId, resetId: out.resetId });
    expect(await carolWs.next("reset")).toEqual({ type: "reset", userId: mom.userId, resetId: out.resetId });
    expect(await adminWs.next("chat")).toEqual({ type: "chat", chatId: direct.id });
    expect(await adminWs.next("device")).toEqual({ type: "device", userId: mom.userId, deviceId: mom.deviceId, revoked: true });
    await momWs.none("reset");
  });

  it("reusing a reset id -> 409", async () => {
    const admin = await insertUserWithDevice({ admin: true });
    const mom = await insertUserWithDevice({ name: "Mom" });
    const r = await signedReset(admin, { userId: mom.userId, identityPub: mom.keys.identityPub });
    expect((await postReset(admin, mom.userId, r.body)).status).toBe(201);
    expect((await postReset(admin, mom.userId, r.body)).status).toBe(409);
  });
});

describe("redeeming a reset invite", () => {
  it("attaches the new identity and device to the same user", async () => {
    const admin = await insertUserWithDevice({ admin: true });
    const mom = await insertUserWithDevice({ name: "Mom" });
    const direct = await createDirect(admin, mom);
    const out = await resetUser(admin, mom);
    const before = await env.DB.prepare("SELECT COUNT(*) AS n FROM users").first<number>("n");
    const { res, keys } = await redeemReset(out.inviteToken, out.resetId, out.claim);
    expect(res.status).toBe(201);
    const body = await res.json<{ userId: string; deviceId: string; isAdmin: boolean; accessToken: string }>();
    expect(body.userId).toBe(mom.userId);
    expect(body.isAdmin).toBe(false);
    expect(await env.DB.prepare("SELECT COUNT(*) AS n FROM users").first<number>("n")).toBe(before);
    const me = await (await api(body.accessToken, "GET", "/me")).json<{ userId: string; name: string }>();
    expect(me).toMatchObject({ userId: mom.userId, name: "Mom" });
    // Still a member of her chats.
    expect((await api(body.accessToken, "GET", `/chats/${direct.id}`)).status).toBe(200);

    const momRow = (await users(admin.accessToken)).find((u) => u.id === mom.userId)!;
    expect(momRow.identityPub).toBe(keys.identityPub);
    expect(momRow.devices.filter((d) => !d.revoked).map((d) => d.id)).toEqual([body.deviceId]);
    // History kept: the old key is in the reset record.
    expect(momRow.resets[0]).toMatchObject({ oldIdentityPub: mom.keys.identityPub, newIdentityPub: keys.identityPub });
    expect(momRow.resets[0].claimSig).toBeTruthy();
    expect(momRow.resets[0].completedAt).toBeGreaterThan(0);
    const ev = await env.DB.prepare("SELECT COUNT(*) AS n FROM events WHERE kind = 'reset_redeemed' AND user_id = ?")
      .bind(mom.userId).first<number>("n");
    expect(ev).toBe(1);
  });

  it("notifies sharing users of the new device and the completed reset", async () => {
    const admin = await insertUserWithDevice({ admin: true });
    const mom = await insertUserWithDevice({ name: "Mom" });
    await createDirect(admin, mom);
    const out = await resetUser(admin, mom);
    const adminWs = await socket(admin);
    const { res } = await redeemReset(out.inviteToken, out.resetId, out.claim);
    const { deviceId } = await res.json<{ deviceId: string }>();
    expect(await adminWs.next("device")).toEqual({ type: "device", userId: mom.userId, deviceId });
    expect(await adminWs.next("reset")).toEqual({ type: "reset", userId: mom.userId, resetId: out.resetId });
  });

  it("redeem without a valid claim -> 400 and the invite stays usable", async () => {
    const admin = await insertUserWithDevice({ admin: true });
    const mom = await insertUserWithDevice({ name: "Mom" });
    const out = await resetUser(admin, mom);
    const wrong = await ed25519();
    expect((await redeemReset(out.inviteToken, out.resetId, wrong)).res.status).toBe(400);
    const k = await makeKeys();
    const noClaim = await SELF.fetch(`${BASE}/api/auth/invite/redeem`, jsonReq("POST", {
      token: out.inviteToken, deviceName: "X", platform: "ios",
      identityPub: k.identityPub, encPub: k.encPub, signPub: k.signPub, certSig: k.certSig,
    }));
    expect(noClaim.status).toBe(400);
    expect((await redeemReset(out.inviteToken, out.resetId, out.claim)).res.status).toBe(201);
  });

  it("a lost redeem response is retried with the same keys", async () => {
    const admin = await insertUserWithDevice({ admin: true });
    const mom = await insertUserWithDevice({ name: "Mom" });
    const out = await resetUser(admin, mom);
    const first = await redeemReset(out.inviteToken, out.resetId, out.claim);
    const a = await first.res.json<{ deviceId: string }>();
    const again = await redeemReset(out.inviteToken, out.resetId, out.claim, first.keys);
    expect(again.res.status).toBe(201);
    const b = await again.res.json<{ userId: string; deviceId: string }>();
    expect(b).toMatchObject({ userId: mom.userId, deviceId: a.deviceId });
    // Other keys can't reuse it.
    expect((await redeemReset(out.inviteToken, out.resetId, out.claim)).res.status).toBe(410);
  });

  it("a newer reset retires the older link", async () => {
    const admin = await insertUserWithDevice({ admin: true });
    const mom = await insertUserWithDevice({ name: "Mom" });
    const first = await resetUser(admin, mom);
    const second = await resetUser(admin, mom);
    expect((await redeemReset(first.inviteToken, first.resetId, first.claim)).res.status).toBe(410);
    expect((await redeemReset(second.inviteToken, second.resetId, second.claim)).res.status).toBe(201);
  });

  it("a second reset after the first completed keeps both keys in the history", async () => {
    const admin = await insertUserWithDevice({ admin: true });
    const mom = await insertUserWithDevice({ name: "Mom" });
    const first = await resetUser(admin, mom);
    const { res, keys } = await redeemReset(first.inviteToken, first.resetId, first.claim);
    const momNow = { ...mom, ...(await res.json<{ accessToken: string }>()), keys };
    const second = await resetUser(admin, momNow as typeof mom);
    const k3 = (await redeemReset(second.inviteToken, second.resetId, second.claim)).keys;
    const row = (await users(admin.accessToken)).find((u) => u.id === mom.userId)!;
    expect(row.resets.map((r) => [r.oldIdentityPub, r.newIdentityPub])).toEqual([
      [mom.keys.identityPub, keys.identityPub],
      [keys.identityPub, k3.identityPub],
    ]);
  });
});

describe("POST /api/admin/users/:id/admin", () => {
  const promote = async (by: TestUser, userId: string, signer: CryptoKey = by.keys.identityPriv) =>
    api(by.accessToken, "POST", `/admin/users/${userId}/admin`, { sig: await sign(signer, promotionMessage(userId, by.userId)) });

  it("promotes a member with a signed promotion, who can then use admin routes at once", async () => {
    const admin = await insertUserWithDevice({ admin: true });
    const dad = await insertUserWithDevice({ name: "Dad" });
    expect((await api(dad.accessToken, "POST", "/admin/invites", { name: "X" })).status).toBe(403);
    expect((await promote(admin, dad.userId)).status).toBe(204);
    expect((await api(dad.accessToken, "POST", "/admin/invites", { name: "X" })).status).toBe(201);
    const row = (await users(admin.accessToken)).find((u) => u.id === dad.userId)!;
    expect(row.isAdmin).toBe(true);
    expect(row.adminProof).toMatchObject({ byUserId: admin.userId, signerPub: admin.keys.identityPub });
    expect((await users(admin.accessToken)).find((u) => u.id === admin.userId)!.adminProof).toBeNull();
    const ev = await env.DB.prepare("SELECT user_id, actor_id FROM events WHERE kind = 'admin_promoted'").first();
    expect(ev).toEqual({ user_id: dad.userId, actor_id: admin.userId });
  });

  it("an unsigned or wrongly signed promotion -> 400", async () => {
    const admin = await insertUserWithDevice({ admin: true });
    const dad = await insertUserWithDevice({ name: "Dad" });
    expect((await api(admin.accessToken, "POST", `/admin/users/${dad.userId}/admin`)).status).toBe(400);
    expect((await promote(admin, dad.userId, (await ed25519()).priv)).status).toBe(400);
  });

  it("non-admin -> 403, unknown user -> 404", async () => {
    const admin = await insertUserWithDevice({ admin: true });
    const dad = await insertUserWithDevice({ name: "Dad" });
    const kid = await insertUserWithDevice({ name: "Kid" });
    expect((await promote(kid, dad.userId)).status).toBe(403);
    expect((await promote(admin, "01JNOPE0000000000000000000")).status).toBe(404);
  });
});

describe("reset races", () => {
  it("a reset whose old key changed under it is refused and changes nothing", async () => {
    const admin = await insertUserWithDevice({ admin: true });
    const mom = await insertUserWithDevice({ name: "Mom" });
    const r = await signedReset(admin, { userId: mom.userId, identityPub: mom.keys.identityPub });
    expect((await postReset(admin, mom.userId, { ...r.body, oldIdentityPub: (await makeKeys()).identityPub })).status).toBe(400);
    // The key moves between the route's check and its batch: run the batch with a stale key.
    await expect(resetAccount(env, {
      statement: { ...r.statement, oldIdentityPub: (await makeKeys()).identityPub },
      sig: r.body.sig,
      signerPub: admin.keys.identityPub,
      recoverySig: null,
      actorId: admin.userId,
      now: Date.now(),
      invite: { tokenHash: "h", name: "Mom", createdBy: admin.userId, expiresAt: Date.now() + 1000 },
    })).rejects.toMatchObject({ code: "conflict" });
    expect((await api(mom.accessToken, "GET", "/me")).status).toBe(200);
    expect(await env.DB.prepare("SELECT COUNT(*) AS n FROM resets").first<number>("n")).toBe(0);
    expect(await env.DB.prepare("SELECT COUNT(*) AS n FROM invites WHERE user_id IS NOT NULL").first<number>("n")).toBe(0);
  });
});

describe("audit events", () => {
  it("revoking a device writes an event", async () => {
    const alice = await insertUserWithDevice();
    const laptop = await addDevice(alice.userId);
    await api(alice.accessToken, "DELETE", `/devices/${laptop}`);
    const ev = await env.DB.prepare("SELECT user_id, actor_id, payload FROM events WHERE kind = 'device_revoked'").first<Record<string, string>>();
    expect(ev).toMatchObject({ user_id: alice.userId, actor_id: alice.userId });
    expect(JSON.parse(ev!.payload)).toEqual({ deviceId: laptop });
  });
});
