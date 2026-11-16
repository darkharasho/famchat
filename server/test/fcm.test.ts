import { beforeEach, describe, expect, it } from "vitest";
import { b64urlDecode } from "../src/lib/encoding";
import {
  accessToken,
  fcmMessage,
  invalidateAccessToken,
  parseServiceAccount,
  sendFcm,
  signJwt,
} from "../src/push/fcm";
import { decodeJwtPart, fakeGoogle, fcmError, testServiceAccount } from "./push-helpers";

beforeEach(() => invalidateAccessToken());

describe("service account", () => {
  it("parses the key file and refuses other JSON", async () => {
    const sa = parseServiceAccount((await testServiceAccount()).json);
    expect(sa.projectId).toBe("famchat");
    expect(sa.clientEmail).toBe("push@famchat.iam.gserviceaccount.com");
    expect(sa.tokenUri).toBe("https://oauth2.googleapis.com/token");
    expect(() => parseServiceAccount('{"project_id":"x"}')).toThrow();
    expect(() => parseServiceAccount("not json")).toThrow();
  });

  it("signs an RS256 JWT for the FCM scope that the public key verifies", async () => {
    const t = await testServiceAccount();
    const jwt = await signJwt(parseServiceAccount(t.json), 1_700_000_000);
    const [h, c, s] = jwt.split(".");
    expect(decodeJwtPart(h)).toEqual({ alg: "RS256", typ: "JWT" });
    expect(decodeJwtPart(c)).toEqual({
      iss: "push@famchat.iam.gserviceaccount.com",
      scope: "https://www.googleapis.com/auth/firebase.messaging",
      aud: "https://oauth2.googleapis.com/token",
      iat: 1_700_000_000,
      exp: 1_700_003_600,
    });
    const ok = await crypto.subtle.verify(
      "RSASSA-PKCS1-v1_5",
      t.publicKey,
      b64urlDecode(s),
      new TextEncoder().encode(`${h}.${c}`),
    );
    expect(ok).toBe(true);
  });
});

describe("access token", () => {
  it("exchanges the JWT once and caches it until five minutes before expiry", async () => {
    const sa = parseServiceAccount((await testServiceAccount()).json);
    const g = fakeGoogle();
    const now = 1_700_000_000_000;
    expect(await accessToken(sa, g.fetcher, now)).toBe("at-1");
    expect(await accessToken(sa, g.fetcher, now + 50 * 60_000)).toBe("at-1");
    expect(g.calls).toHaveLength(1);
    const form = new URLSearchParams(g.calls[0].body);
    expect(form.get("grant_type")).toBe("urn:ietf:params:oauth:grant-type:jwt-bearer");
    expect(form.get("assertion")?.split(".")).toHaveLength(3);
    expect(await accessToken(sa, g.fetcher, now + 56 * 60_000)).toBe("at-2");
    invalidateAccessToken();
    expect(await accessToken(sa, g.fetcher, now + 56 * 60_000)).toBe("at-3");
  });

  it("a different service account gets its own token", async () => {
    const g = fakeGoogle();
    await accessToken(parseServiceAccount((await testServiceAccount("a@x.iam.gserviceaccount.com")).json), g.fetcher);
    await accessToken(parseServiceAccount((await testServiceAccount("b@x.iam.gserviceaccount.com")).json), g.fetcher);
    expect(g.calls).toHaveLength(2);
  });

  it("a refused exchange throws", async () => {
    const sa = parseServiceAccount((await testServiceAccount()).json);
    await expect(accessToken(sa, async () => new Response("no", { status: 400 }))).rejects.toThrow();
  });
});

describe("FCM message", () => {
  it("carries the title, body and chat id with per-platform blocks", () => {
    const m = fcmMessage("tok", { title: "Mom", body: "New message", chatId: "01CHAT" }, "https://famchat.dev");
    expect(m).toEqual({
      message: {
        token: "tok",
        notification: { title: "Mom", body: "New message" },
        data: { chatId: "01CHAT" },
        android: { priority: "high", notification: { channel_id: "messages", tag: "01CHAT" } },
        apns: { headers: { "apns-priority": "10" }, payload: { aps: { sound: "default", "thread-id": "01CHAT" } } },
        webpush: { notification: { tag: "01CHAT" }, fcm_options: { link: "https://famchat.dev/chats/01CHAT" } },
      },
    });
  });

  it("classifies FCM answers", async () => {
    const sa = parseServiceAccount((await testServiceAccount()).json);
    const note = { title: "t", body: "b", chatId: "c" };
    const cases: [Response | Error, string][] = [
      [Response.json({ name: "x" }), "ok"],
      [fcmError(404, "UNREGISTERED"), "stale"],
      [fcmError(400, "UNREGISTERED"), "stale"],
      [fcmError(403, "SENDER_ID_MISMATCH"), "stale"],
      [fcmError(401, "UNAUTHENTICATED"), "auth"],
      [fcmError(429, "QUOTA_EXCEEDED"), "retry"],
      [fcmError(503, "UNAVAILABLE"), "retry"],
      [new Error("network"), "retry"],
      [fcmError(400, "INVALID_ARGUMENT"), "error"],
    ];
    for (const [answer, want] of cases) {
      const fetcher = (async () => {
        if (answer instanceof Error) throw answer;
        return answer;
      }) as typeof fetch;
      expect(await sendFcm(sa, "at", "tok", note, "https://famchat.dev", fetcher)).toBe(want);
    }
  });

  it("posts to the project's send endpoint with the bearer token", async () => {
    const sa = parseServiceAccount((await testServiceAccount()).json);
    const g = fakeGoogle();
    await sendFcm(sa, "at-9", "tok", { title: "t", body: "b", chatId: "c" }, "https://famchat.dev", g.fetcher);
    expect(g.calls[0].url).toBe("https://fcm.googleapis.com/v1/projects/famchat/messages:send");
    expect(g.calls[0].headers.get("authorization")).toBe("Bearer at-9");
  });
});
