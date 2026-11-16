import { env, SELF } from "cloudflare:test";
import { newId } from "../src/lib/ids";
import { api, type TestUser } from "./chat-helpers";
import { BASE } from "./helpers";

export const MiB = 1024 * 1024;
export const GiB = 1024 * MiB;

export function randomBytes(n: number): Uint8Array {
  const out = new Uint8Array(n);
  for (let i = 0; i < n; i += 65536) crypto.getRandomValues(out.subarray(i, Math.min(n, i + 65536)));
  return out;
}

export function upload(
  u: TestUser,
  q: { chatId: string; key?: string; kind?: string; messageId?: string },
  body: BodyInit,
  headers: Record<string, string> = {},
): Promise<Response> {
  const params = new URLSearchParams({ chatId: q.chatId, key: q.key ?? newId(), kind: q.kind ?? "photo" });
  if (q.messageId) params.set("messageId", q.messageId);
  return SELF.fetch(`${BASE}/api/media?${params}`, {
    method: "POST",
    headers: { authorization: `Bearer ${u.accessToken}`, "content-type": "application/octet-stream", ...headers },
    body,
  });
}

export function download(u: TestUser, key: string): Promise<Response> {
  return api(u.accessToken, "GET", `/media/${key}`);
}

export async function usage(): Promise<number> {
  return (await env.DB.prepare("SELECT bytes FROM media_usage WHERE id = 1").first<{ bytes: number }>())!.bytes;
}

/** Inserts a media row directly (pretending [bytes] were stored) plus a tiny R2 object. */
export async function insertMedia(o: {
  chatId: string;
  uploader: TestUser;
  bytes: number;
  createdAt: number;
  messageId?: string;
  kind?: string;
}): Promise<string> {
  const key = newId(o.createdAt);
  await env.MEDIA.put(key, new Uint8Array([1, 2, 3]));
  await env.DB.prepare(
    `INSERT INTO media (key, uploader_id, uploader_device_id, chat_id, message_id, kind, bytes, created_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
  ).bind(key, o.uploader.userId, o.uploader.deviceId, o.chatId, o.messageId ?? null, o.kind ?? "photo", o.bytes, o.createdAt).run();
  return key;
}

export type Frame = Record<string, unknown> & { type: string };

/** Opens a hub socket for [u] and collects frames. */
export async function listen(u: TestUser) {
  const t = await (await api(u.accessToken, "POST", "/ws/ticket")).json<{ ticket: string }>();
  const res = await SELF.fetch(`${BASE}/api/ws?ticket=${encodeURIComponent(t.ticket)}`, { headers: { upgrade: "websocket" } });
  const ws = res.webSocket!;
  ws.accept();
  const frames: Frame[] = [];
  ws.addEventListener("message", (e) => frames.push(JSON.parse(e.data as string) as Frame));
  return {
    frames,
    async next(type: string, timeoutMs = 2000): Promise<Frame> {
      const deadline = Date.now() + timeoutMs;
      for (;;) {
        const f = frames.find((m) => m.type === type);
        if (f) return f;
        if (Date.now() > deadline) throw new Error(`no ${type}: ${JSON.stringify(frames)}`);
        await new Promise((r) => setTimeout(r, 20));
      }
    },
    close() {
      try {
        ws.close(1000, "done");
      } catch {
        /* closed */
      }
    },
  };
}
