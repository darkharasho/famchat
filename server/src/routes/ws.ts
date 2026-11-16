import { Hono } from "hono";
import type { AppEnv } from "../env";
import { hubStub } from "../hub";
import { ApiError } from "../lib/errors";
import { randomToken, sha256Hex } from "../lib/tokens";
import { requireAuth } from "../middleware/auth";

export const TICKET_TTL_MS = 30 * 1000;

export const ws = new Hono<AppEnv>();

/** A one-time, short-lived ticket: browsers can't set headers on a WebSocket, so the token can't go there. */
ws.post("/ticket", requireAuth, async (c) => {
  const ticket = randomToken();
  const now = Date.now();
  const expiresAt = now + TICKET_TTL_MS;
  await c.env.DB.batch([
    c.env.DB.prepare("DELETE FROM ws_tickets WHERE expires_at < ?").bind(now),
    c.env.DB.prepare("INSERT INTO ws_tickets (hash, user_id, device_id, expires_at) VALUES (?, ?, ?, ?)")
      .bind(await sha256Hex(ticket), c.get("userId"), c.get("deviceId"), expiresAt),
  ]);
  return c.json({ ticket, expiresAt });
});

/** Consumes the ticket and hands the upgrade to FamilyHub with the device's identity. */
ws.get("/", async (c) => {
  if (c.req.header("upgrade")?.toLowerCase() !== "websocket") throw new ApiError("upgrade_required");
  const ticket = c.req.query("ticket");
  if (!ticket) throw new ApiError("unauthorized");
  const row = await c.env.DB.prepare(
    `DELETE FROM ws_tickets WHERE hash = ? RETURNING user_id, device_id, expires_at`,
  ).bind(await sha256Hex(ticket)).first<{ user_id: string; device_id: string; expires_at: number }>();
  if (!row || row.expires_at < Date.now()) throw new ApiError("unauthorized");
  const live = await c.env.DB.prepare(
    "SELECT u.reviewer FROM devices d JOIN users u ON u.id = d.user_id WHERE d.id = ? AND d.user_id = ? AND d.revoked_at IS NULL",
  ).bind(row.device_id, row.user_id).first<{ reviewer: number }>();
  if (!live) throw new ApiError("unauthorized");
  return hubStub(c.env).fetch("https://hub/ws", {
    headers: {
      upgrade: "websocket",
      "x-famchat-user": row.user_id,
      "x-famchat-device": row.device_id,
      // Presence stays on the caller's side (docs/protocol.md "Reviewer accounts").
      "x-famchat-side": live.reviewer === 1 ? "reviewer" : "family",
    },
  });
});
