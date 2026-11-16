import { Hono } from "hono";
import type { AppEnv } from "./env";
import { ApiError, errorResponse } from "./lib/errors";
import { admin } from "./routes/admin";

export const app = new Hono<AppEnv>().basePath("/api");

app.get("/health", (c) => c.json({ ok: true }));
app.route("/admin", admin);

app.notFound(() => errorResponse("not_found"));
app.onError((err) => {
  if (err instanceof ApiError) return errorResponse(err.code);
  console.error(err);
  return errorResponse("internal");
});

export default app;
