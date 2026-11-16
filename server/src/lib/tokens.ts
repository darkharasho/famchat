import { sign, verify } from "hono/jwt";
import type { Env } from "../env";
import { b64urlEncode, toHex } from "./encoding";

export const ACCESS_TTL_SECONDS = 900;

export interface AccessClaims {
  sub: string;
  dev: string;
  adm: boolean;
}

export function randomToken(): string {
  return b64urlEncode(crypto.getRandomValues(new Uint8Array(32)));
}

export async function sha256Hex(s: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return toHex(new Uint8Array(digest));
}

export async function signAccessToken(
  env: Pick<Env, "TOKEN_SECRET">,
  claims: AccessClaims,
  ttlSeconds: number = ACCESS_TTL_SECONDS,
): Promise<string> {
  const exp = Math.floor(Date.now() / 1000) + ttlSeconds;
  return sign({ sub: claims.sub, dev: claims.dev, adm: claims.adm, exp }, env.TOKEN_SECRET, "HS256");
}

export async function verifyAccessToken(
  env: Pick<Env, "TOKEN_SECRET">,
  token: string,
): Promise<AccessClaims | null> {
  try {
    const p = await verify(token, env.TOKEN_SECRET, "HS256");
    if (typeof p.sub !== "string" || typeof p.dev !== "string" || typeof p.adm !== "boolean") {
      return null;
    }
    return { sub: p.sub, dev: p.dev, adm: p.adm };
  } catch {
    return null;
  }
}
