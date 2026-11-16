import { Hono } from "hono";
import type { AppEnv } from "./env";
import { ApiError, errorResponse } from "./lib/errors";
import { admin } from "./routes/admin";
import { auth } from "./routes/auth";
import { chats } from "./routes/chats";
import { devices } from "./routes/devices";
import { keys } from "./routes/keys";
import { me } from "./routes/me";
import { users } from "./routes/users";
import { ws } from "./routes/ws";

export const app = new Hono<AppEnv>().basePath("/api");

app.get("/health", (c) => c.json({ ok: true }));
app.route("/admin", admin);
app.route("/auth", auth);
app.route("/devices", devices);
app.route("/me", me);
app.route("/users", users);
app.route("/chats", chats);
app.route("/keys", keys);
app.route("/ws", ws);

app.notFound(() => errorResponse("not_found"));
app.onError((err) => {
  if (err instanceof ApiError) return errorResponse(err.code);
  console.error(err);
  return errorResponse("internal");
});

export { FamilyHub } from "./hub";

export default app;
