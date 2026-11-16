import { b64urlEncode } from "../src/lib/encoding";

const CERT_CONTEXT = new TextEncoder().encode("famchat-device-cert-v1");

export function certMessage(encPub: Uint8Array, signPub: Uint8Array): Uint8Array {
  const msg = new Uint8Array(CERT_CONTEXT.length + 64);
  msg.set(CERT_CONTEXT, 0);
  msg.set(encPub, CERT_CONTEXT.length);
  msg.set(signPub, CERT_CONTEXT.length + 32);
  return msg;
}

async function ed25519Pair(): Promise<{ priv: CryptoKey; pub: Uint8Array }> {
  const kp = (await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"])) as CryptoKeyPair;
  const pub = new Uint8Array((await crypto.subtle.exportKey("raw", kp.publicKey)) as ArrayBuffer);
  return { priv: kp.privateKey, pub };
}

export interface TestKeys {
  identityPub: string;
  encPub: string;
  signPub: string;
  certSig: string;
  identityPriv: CryptoKey;
  raw: { encPub: Uint8Array; signPub: Uint8Array };
}

export async function makeKeys(): Promise<TestKeys> {
  const identity = await ed25519Pair();
  const sign = await ed25519Pair();
  const encPub = crypto.getRandomValues(new Uint8Array(32));
  const sig = new Uint8Array(
    await crypto.subtle.sign("Ed25519", identity.priv, certMessage(encPub, sign.pub)),
  );
  return {
    identityPub: b64urlEncode(identity.pub),
    encPub: b64urlEncode(encPub),
    signPub: b64urlEncode(sign.pub),
    certSig: b64urlEncode(sig),
    identityPriv: identity.priv,
    raw: { encPub, signPub: sign.pub },
  };
}

import { env } from "cloudflare:test";
import { newId } from "../src/lib/ids";
import { signAccessToken } from "../src/lib/tokens";

export const BASE = "https://famchat.dev";

export async function resetDb(): Promise<void> {
  await env.DB.batch([
    env.DB.prepare("DELETE FROM devices"),
    env.DB.prepare("DELETE FROM invites"),
    env.DB.prepare("DELETE FROM users"),
  ]);
}

/** Inserts a user + device row directly and returns an access token for it. */
export async function insertUserWithDevice(opts: { admin?: boolean; name?: string } = {}) {
  const keys = await makeKeys();
  const userId = newId();
  const deviceId = newId();
  const now = Date.now();
  await env.DB.batch([
    env.DB.prepare(
      "INSERT INTO users (id, name, is_admin, identity_pub, created_at) VALUES (?, ?, ?, ?, ?)",
    ).bind(userId, opts.name ?? "Test", opts.admin ? 1 : 0, keys.identityPub, now),
    env.DB.prepare(
      `INSERT INTO devices (id, user_id, name, platform, enc_pub, sign_pub, cert_sig, created_at, last_seen)
       VALUES (?, ?, 'Phone', 'android', ?, ?, ?, ?, ?)`,
    ).bind(deviceId, userId, keys.encPub, keys.signPub, keys.certSig, now, now),
  ]);
  const accessToken = await signAccessToken(env, { sub: userId, dev: deviceId, adm: !!opts.admin });
  return { userId, deviceId, accessToken, keys };
}

export function jsonReq(method: string, body?: unknown, headers: Record<string, string> = {}): RequestInit {
  return {
    method,
    headers: { "content-type": "application/json", ...headers },
    body: body === undefined ? undefined : JSON.stringify(body),
  };
}
