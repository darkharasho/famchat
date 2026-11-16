import { env } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { b64urlDecode, b64urlEncode } from "../src/lib/encoding";
import { newId } from "../src/lib/ids";
import { randomToken, sha256Hex, signAccessToken, verifyAccessToken } from "../src/lib/tokens";
import { verifyDeviceCert } from "../src/lib/devicecert";
import { ApiError } from "../src/lib/errors";
import { certMessage, makeKeys } from "./helpers";
import dartCert from "./fixtures/dart-device-cert.json";

describe("b64url", () => {
  it("round-trips", () => {
    for (const n of [0, 1, 31, 32, 64]) {
      const bytes = crypto.getRandomValues(new Uint8Array(n));
      const s = b64urlEncode(bytes);
      expect(s).not.toMatch(/[=+/]/);
      expect(b64urlDecode(s)).toEqual(bytes);
    }
  });

  it("rejects garbage with invalid_request", () => {
    expect(() => b64urlDecode("not base64!!")).toThrow(ApiError);
    try {
      b64urlDecode("@@@");
    } catch (e) {
      expect((e as ApiError).code).toBe("invalid_request");
    }
  });
});

describe("newId", () => {
  it("is 26 chars and increases over time", async () => {
    const a = newId();
    await new Promise((r) => setTimeout(r, 2));
    const b = newId();
    expect(a).toMatch(/^[0-9A-HJKMNP-TV-Z]{26}$/);
    expect(b.length).toBe(26);
    expect(a < b).toBe(true);
  });
});

describe("tokens", () => {
  it("randomToken is 32 bytes b64url and unique", () => {
    const t = randomToken();
    expect(b64urlDecode(t).length).toBe(32);
    expect(randomToken()).not.toBe(t);
  });

  it("sha256Hex of abc", async () => {
    expect(await sha256Hex("abc")).toBe(
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
    );
  });

  it("access token round-trips", async () => {
    const t = await signAccessToken(env, { sub: "u1", dev: "d1", adm: true });
    expect(await verifyAccessToken(env, t)).toEqual({ sub: "u1", dev: "d1", adm: true });
  });

  it("expired token -> null", async () => {
    const t = await signAccessToken(env, { sub: "u1", dev: "d1", adm: false }, -60);
    expect(await verifyAccessToken(env, t)).toBeNull();
  });

  it("tampered token -> null", async () => {
    const t = await signAccessToken(env, { sub: "u1", dev: "d1", adm: false });
    const [h, p, s] = t.split(".");
    const forged = btoa(JSON.stringify({ sub: "u1", dev: "d1", adm: true, exp: 9e9 }))
      .replace(/=+$/, "").replace(/\+/g, "-").replace(/\//g, "_");
    expect(await verifyAccessToken(env, `${h}.${forged}.${s}`)).toBeNull();
    expect(await verifyAccessToken(env, `${h}.${p}.${s}x`)).toBeNull();
    expect(await verifyAccessToken(env, "garbage")).toBeNull();
  });

  it("token signed with another secret -> null", async () => {
    const t = await signAccessToken({ ...env, TOKEN_SECRET: "other" }, { sub: "u", dev: "d", adm: false });
    expect(await verifyAccessToken(env, t)).toBeNull();
  });
});

describe("verifyDeviceCert", () => {
  it("accepts Dart-generated cert", async () => {
    const c = dartCert;
    expect(await verifyDeviceCert(c.identityPub, c.encPub, c.signPub, c.certSig)).toBe(true);
  });

  it("rejects Dart cert with swapped keys", async () => {
    const c = dartCert;
    expect(await verifyDeviceCert(c.identityPub, c.signPub, c.encPub, c.certSig)).toBe(false);
  });

  it("valid cert verifies", async () => {
    const k = await makeKeys();
    expect(await verifyDeviceCert(k.identityPub, k.encPub, k.signPub, k.certSig)).toBe(true);
  });

  it("swapped encPub/signPub fails", async () => {
    const k = await makeKeys();
    expect(await verifyDeviceCert(k.identityPub, k.signPub, k.encPub, k.certSig)).toBe(false);
  });

  it("cert from a different identity fails", async () => {
    const k = await makeKeys();
    const other = await makeKeys();
    expect(await verifyDeviceCert(other.identityPub, k.encPub, k.signPub, k.certSig)).toBe(false);
  });

  it("31-byte key -> false", async () => {
    const k = await makeKeys();
    const short = b64urlEncode(k.raw.encPub.slice(0, 31));
    expect(await verifyDeviceCert(k.identityPub, short, k.signPub, k.certSig)).toBe(false);
  });

  it("garbage base64 -> false", async () => {
    const k = await makeKeys();
    expect(await verifyDeviceCert("@@@", k.encPub, k.signPub, k.certSig)).toBe(false);
    expect(await verifyDeviceCert(k.identityPub, k.encPub, k.signPub, "!!")).toBe(false);
  });

  it("cert message layout is context || encPub || signPub", () => {
    const m = certMessage(new Uint8Array(32).fill(1), new Uint8Array(32).fill(2));
    expect(new TextDecoder().decode(m.slice(0, 22))).toBe("famchat-device-cert-v1");
    expect(m.length).toBe(22 + 64);
  });
});
