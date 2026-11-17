import { Hono } from "hono";
import type { AppEnv, Env } from "./env";
import type { PushJob } from "./hub";
import { handlePushBatch } from "./push/consumer";
import { ApiError, errorResponse } from "./lib/errors";
import { admin } from "./routes/admin";
import { auth } from "./routes/auth";
import { chats } from "./routes/chats";
import { devices } from "./routes/devices";
import { keys } from "./routes/keys";
import { media } from "./routes/media";
import { me } from "./routes/me";
import { pairing } from "./routes/pairing";
import { preview } from "./routes/preview";
import { users } from "./routes/users";
import { ws } from "./routes/ws";

export const app = new Hono<AppEnv>().basePath("/api");

app.get("/health", (c) => c.json({ ok: true }));
app.route("/admin", admin);
app.route("/auth", auth);
// Before /devices: its requireAuth would otherwise catch the unauthenticated pairing routes.
app.route("/devices/pair", pairing);
app.route("/devices", devices);
app.route("/me", me);
app.route("/users", users);
app.route("/chats", chats);
app.route("/keys", keys);
app.route("/media", media);
app.route("/preview", preview);
app.route("/ws", ws);

app.notFound(() => errorResponse("not_found"));
app.onError((err) => {
  if (err instanceof ApiError) return errorResponse(err.code);
  console.error(err);
  return errorResponse("internal");
});

export { FamilyHub } from "./hub";

export default {
  fetch: app.fetch,
  queue: (batch, env) => handlePushBatch(batch, env),
} satisfies ExportedHandler<Env, PushJob>;
