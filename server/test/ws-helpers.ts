import { SELF } from "cloudflare:test";
import { expect } from "vitest";
import { api, type TestUser } from "./chat-helpers";
import { BASE } from "./helpers";

const open: WebSocket[] = [];

/** Closes every socket opened with [socket]; call from afterEach. */
export function closeSockets(): void {
  for (const ws of open.splice(0)) {
    try {
      ws.close(1000, "done");
    } catch {
      /* closed */
    }
  }
}

/** A hub socket for [u] with a small inbox. */
export async function socket(u: TestUser) {
  const t = await (await api(u.accessToken, "POST", "/ws/ticket")).json<{ ticket: string }>();
  const res = await SELF.fetch(`${BASE}/api/ws?ticket=${encodeURIComponent(t.ticket)}`, { headers: { upgrade: "websocket" } });
  const ws = res.webSocket!;
  ws.accept();
  open.push(ws);
  const inbox: Record<string, unknown>[] = [];
  ws.addEventListener("message", (e) => inbox.push(JSON.parse(e.data as string)));
  return {
    send(m: unknown) {
      ws.send(JSON.stringify(m));
    },
    async next(type: string) {
      for (let i = 0; i < 100; i++) {
        const j = inbox.findIndex((m) => m.type === type);
        if (j >= 0) return inbox.splice(j, 1)[0];
        await new Promise((r) => setTimeout(r, 20));
      }
      throw new Error(`no ${type}: ${JSON.stringify(inbox)}`);
    },
    async none(type: string) {
      await new Promise((r) => setTimeout(r, 150));
      expect(inbox.filter((m) => m.type === type)).toEqual([]);
    },
  };
}
