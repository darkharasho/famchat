import { b64urlDecode } from "../src/lib/encoding";

export interface TestAccount {
  json: string;
  publicKey: CryptoKey;
}

/** A service-account key file with a fresh RSA key, like the one Firebase hands out. */
export async function testServiceAccount(email = "push@famchat.iam.gserviceaccount.com"): Promise<TestAccount> {
  const kp = (await crypto.subtle.generateKey(
    { name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" },
    true,
    ["sign", "verify"],
  )) as CryptoKeyPair;
  const der = new Uint8Array((await crypto.subtle.exportKey("pkcs8", kp.privateKey)) as ArrayBuffer);
  const b64 = btoa(String.fromCharCode(...der)).replace(/.{64}/g, "$&\n");
  const pem = `-----BEGIN PRIVATE KEY-----\n${b64}\n-----END PRIVATE KEY-----\n`;
  return {
    json: JSON.stringify({
      type: "service_account",
      project_id: "famchat",
      private_key_id: "k1",
      private_key: pem,
      client_email: email,
      token_uri: "https://oauth2.googleapis.com/token",
    }),
    publicKey: kp.publicKey,
  };
}

export interface Call {
  url: string;
  body: string;
  headers: Headers;
}

/**
 * A fetch that answers Google's token endpoint with "at-<n>" and FCM sends with [fcm] (default 200),
 * and records every call.
 */
export function fakeGoogle(fcm: (token: string) => Response = () => Response.json({ name: "projects/famchat/messages/1" })) {
  const calls: Call[] = [];
  let tokens = 0;
  const fetcher = async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = String(input);
    const body = typeof init?.body === "string" ? init.body : init?.body ? String(init.body) : "";
    calls.push({ url, body, headers: new Headers(init?.headers) });
    if (url === "https://oauth2.googleapis.com/token") {
      return Response.json({ access_token: `at-${++tokens}`, expires_in: 3599, token_type: "Bearer" });
    }
    if (url.startsWith("https://fcm.googleapis.com/")) {
      return fcm((JSON.parse(body) as { message: { token: string } }).message.token);
    }
    return new Response("unexpected", { status: 500 });
  };
  return { calls, fetcher: fetcher as typeof fetch, sends: () => calls.filter((c) => c.url.startsWith("https://fcm")) };
}

export function decodeJwtPart(part: string): Record<string, unknown> {
  return JSON.parse(new TextDecoder().decode(b64urlDecode(part))) as Record<string, unknown>;
}

export const fcmError = (status: number, code: string) =>
  Response.json(
    { error: { code: status, status: code, details: [{ "@type": "type.googleapis.com/google.firebase.fcm.v1.FcmError", errorCode: code }] } },
    { status },
  );
