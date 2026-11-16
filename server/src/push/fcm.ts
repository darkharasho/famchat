// Firebase Cloud Messaging over HTTP v1. A Google OAuth token comes from a JWT signed with the
// service account's RSA key (WebCrypto, RS256) and is cached until shortly before it expires.
import { b64urlEncode } from "../lib/encoding";

export type Fetch = typeof fetch;

export interface ServiceAccount {
  projectId: string;
  clientEmail: string;
  privateKey: string;
  tokenUri: string;
}

const SCOPE = "https://www.googleapis.com/auth/firebase.messaging";
const DEFAULT_TOKEN_URI = "https://oauth2.googleapis.com/token";

/** The fields we need from a service-account key file; throws on anything else. */
export function parseServiceAccount(json: string): ServiceAccount {
  const o = JSON.parse(json) as Record<string, unknown>;
  const { project_id, client_email, private_key, token_uri } = o;
  if (typeof project_id !== "string" || typeof client_email !== "string" || typeof private_key !== "string") {
    throw new Error("not a service-account key");
  }
  if (!private_key.includes("PRIVATE KEY")) throw new Error("not a service-account key");
  return {
    projectId: project_id,
    clientEmail: client_email,
    privateKey: private_key,
    tokenUri: typeof token_uri === "string" && token_uri.startsWith("https://") ? token_uri : DEFAULT_TOKEN_URI,
  };
}

const enc = new TextEncoder();
const b64urlJson = (v: unknown) => b64urlEncode(enc.encode(JSON.stringify(v)));

async function importKey(pem: string): Promise<CryptoKey> {
  const body = pem.replace(/-----(BEGIN|END) PRIVATE KEY-----/g, "").replace(/\s+/g, "");
  const der = Uint8Array.from(atob(body), (ch) => ch.charCodeAt(0));
  return crypto.subtle.importKey("pkcs8", der, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["sign"]);
}

/** The signed assertion exchanged for an access token. [nowSec] is Unix seconds. */
export async function signJwt(sa: ServiceAccount, nowSec: number): Promise<string> {
  const head = b64urlJson({ alg: "RS256", typ: "JWT" });
  const claims = b64urlJson({ iss: sa.clientEmail, scope: SCOPE, aud: sa.tokenUri, iat: nowSec, exp: nowSec + 3600 });
  const input = `${head}.${claims}`;
  const sig = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", await importKey(sa.privateKey), enc.encode(input));
  return `${input}.${b64urlEncode(new Uint8Array(sig))}`;
}

// One token per isolate, keyed by the service account, so a rotated key gets a new one.
let cached: { key: string; token: string; expiresAt: number } | null = null;

/** Forgets the cached token (after FCM said 401). */
export function invalidateAccessToken(): void {
  cached = null;
}

export async function accessToken(sa: ServiceAccount, fetcher: Fetch, now = Date.now()): Promise<string> {
  const key = `${sa.clientEmail}\n${sa.privateKey}`;
  if (cached && cached.key === key && cached.expiresAt > now) return cached.token;
  const res = await fetcher(sa.tokenUri, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion: await signJwt(sa, Math.floor(now / 1000)),
    }),
  });
  if (!res.ok) throw new Error(`oauth token: ${res.status}`);
  const body = (await res.json()) as { access_token?: unknown; expires_in?: unknown };
  if (typeof body.access_token !== "string") throw new Error("oauth token: no access_token");
  const ttl = typeof body.expires_in === "number" ? body.expires_in : 3600;
  // Renew five minutes early.
  cached = { key, token: body.access_token, expiresAt: now + Math.max(0, ttl - 300) * 1000 };
  return body.access_token;
}

/** What shows on the device. [chatId] null for the test notification. */
export interface Notification {
  title: string;
  body: string;
  chatId: string | null;
}

/** One FCM v1 message for [token]: the visible text plus the chat id, with per-platform blocks. */
export function fcmMessage(token: string, n: Notification, appOrigin: string) {
  const tag = n.chatId ?? "test";
  return {
    message: {
      token,
      notification: { title: n.title, body: n.body },
      data: n.chatId ? { chatId: n.chatId } : {},
      android: { priority: "high", notification: { channel_id: "messages", tag } },
      apns: { headers: { "apns-priority": "10" }, payload: { aps: { sound: "default", "thread-id": tag } } },
      webpush: {
        notification: { tag },
        fcm_options: { link: n.chatId ? `${appOrigin}/chats/${n.chatId}` : `${appOrigin}/` },
      },
    },
  };
}

/**
 * ok; stale: the token is dead (404, UNREGISTERED, or another project's token) and should be
 * cleared; retry: try again later (429, 5xx, network); auth: our access token was refused;
 * error: anything else (logged, not retried).
 */
export type SendResult = "ok" | "stale" | "retry" | "auth" | "error";

export async function sendFcm(
  sa: ServiceAccount,
  accessTok: string,
  token: string,
  n: Notification,
  appOrigin: string,
  fetcher: Fetch,
): Promise<SendResult> {
  let res: Response;
  try {
    res = await fetcher(`https://fcm.googleapis.com/v1/projects/${encodeURIComponent(sa.projectId)}/messages:send`, {
      method: "POST",
      headers: { authorization: `Bearer ${accessTok}`, "content-type": "application/json" },
      body: JSON.stringify(fcmMessage(token, n, appOrigin)),
    });
  } catch (e) {
    console.error("fcm send failed", e);
    return "retry";
  }
  if (res.ok) return "ok";
  const text = await res.text().catch(() => "");
  if (res.status === 404 || text.includes("UNREGISTERED") || text.includes("SENDER_ID_MISMATCH")) return "stale";
  if (res.status === 401) return "auth";
  if (res.status === 429 || res.status >= 500) return "retry";
  console.error("fcm send refused", res.status, text.slice(0, 500));
  return "error";
}
