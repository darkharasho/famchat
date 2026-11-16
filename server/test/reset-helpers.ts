import { SELF } from "cloudflare:test";
import { b64urlEncode } from "../src/lib/encoding";
import { newId } from "../src/lib/ids";
import { claimMessage, recoveryKeyMessage, resetMessage, type ResetStatement } from "../src/lib/reset";
import { api, type TestUser } from "./chat-helpers";
import { BASE, jsonReq, makeKeys, type TestKeys } from "./helpers";

export async function ed25519(): Promise<{ priv: CryptoKey; pub: string }> {
  const kp = (await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"])) as CryptoKeyPair;
  const pub = new Uint8Array((await crypto.subtle.exportKey("raw", kp.publicKey)) as ArrayBuffer);
  return { priv: kp.privateKey, pub: b64urlEncode(pub) };
}

export async function sign(priv: CryptoKey, msg: Uint8Array): Promise<string> {
  return b64urlEncode(new Uint8Array(await crypto.subtle.sign("Ed25519", priv, msg)));
}

export interface ResetBody {
  resetId: string;
  oldIdentityPub: string;
  claimPub: string;
  createdAt: number;
  sig: string;
}

/** A reset statement for [target] signed by [admin]'s identity key, and its claim key. */
export async function signedReset(
  admin: TestUser,
  target: { userId: string; identityPub: string },
  over: Partial<ResetStatement> = {},
  signer: CryptoKey = admin.keys.identityPriv,
) {
  const claim = await ed25519();
  const st: ResetStatement = {
    resetId: newId(),
    userId: target.userId,
    signerUserId: admin.userId,
    signerKind: "admin",
    oldIdentityPub: target.identityPub,
    claimPub: claim.pub,
    createdAt: Date.now(),
    ...over,
  };
  const body: ResetBody = {
    resetId: st.resetId,
    oldIdentityPub: st.oldIdentityPub,
    claimPub: st.claimPub,
    createdAt: st.createdAt,
    sig: await sign(signer, resetMessage(st)),
  };
  return { body, claim, statement: st };
}

export async function postReset(admin: TestUser, userId: string, body: unknown) {
  return api(admin.accessToken, "POST", `/admin/users/${userId}/reset`, body);
}

/** Admin resets [target]; returns the invite token and claim key. */
export async function resetUser(admin: TestUser, target: TestUser) {
  const r = await signedReset(admin, { userId: target.userId, identityPub: target.keys.identityPub });
  const res = await postReset(admin, target.userId, r.body);
  if (res.status !== 201) throw new Error(`reset failed ${res.status} ${await res.text()}`);
  const out = await res.json<{ resetId: string; inviteToken: string; inviteUrl: string; expiresAt: number }>();
  return { ...out, claim: r.claim, statement: r.statement };
}

/** Redeems a reset invite with fresh keys and a valid claim. */
export async function redeemReset(token: string, resetId: string, claim: { priv: CryptoKey }, keys?: TestKeys) {
  const k = keys ?? (await makeKeys());
  const res = await SELF.fetch(
    `${BASE}/api/auth/invite/redeem`,
    jsonReq("POST", {
      token,
      deviceName: "New phone",
      platform: "ios",
      identityPub: k.identityPub,
      encPub: k.encPub,
      signPub: k.signPub,
      certSig: k.certSig,
      resetClaimSig: await sign(claim.priv, claimMessage(resetId, k.identityPub)),
    }),
  );
  return { res, keys: k };
}

export async function registerRecovery(admin: TestUser) {
  const rk = await ed25519();
  const sig = await sign(admin.keys.identityPriv, recoveryKeyMessage(admin.userId, rk.pub));
  const res = await api(admin.accessToken, "POST", "/admin/recovery-key", { recoveryPub: rk.pub, sig });
  return { res, rk };
}
