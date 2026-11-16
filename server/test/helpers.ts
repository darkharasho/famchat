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
