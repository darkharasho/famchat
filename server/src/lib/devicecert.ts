import { b64urlDecode } from "./encoding";

const CONTEXT = new TextEncoder().encode("famchat-device-cert-v1");

/** Checks Ed25519(identity, "famchat-device-cert-v1" || encPub || signPub). Never throws. */
export async function verifyDeviceCert(
  identityPub: string,
  encPub: string,
  signPub: string,
  certSig: string,
): Promise<boolean> {
  try {
    const id = b64urlDecode(identityPub);
    const enc = b64urlDecode(encPub);
    const sgn = b64urlDecode(signPub);
    const sig = b64urlDecode(certSig);
    if (id.length !== 32 || enc.length !== 32 || sgn.length !== 32 || sig.length !== 64) return false;
    const msg = new Uint8Array(CONTEXT.length + 64);
    msg.set(CONTEXT, 0);
    msg.set(enc, CONTEXT.length);
    msg.set(sgn, CONTEXT.length + 32);
    const key = await crypto.subtle.importKey("raw", id, { name: "Ed25519" }, false, ["verify"]);
    return await crypto.subtle.verify("Ed25519", key, sig, msg);
  } catch {
    return false;
  }
}
