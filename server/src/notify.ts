import type { Env } from "./env";
import { hubStub } from "./hub";

/** Sends a hub event to every open socket of [userIds]. Never throws: events are hints, REST is the truth. */
export async function notify(env: Env, userIds: string[], event: Record<string, unknown>): Promise<void> {
  if (userIds.length === 0) return;
  try {
    await hubStub(env).notify(userIds, event);
  } catch (e) {
    console.error("hub notify failed", e);
  }
}

/**
 * Tells the hub that due times may have moved (a reminder set or cleared, a member left): it re-arms
 * its alarm. Never throws: the alarm still fires at its old time and re-arms then.
 */
export async function timersChanged(env: Env): Promise<void> {
  try {
    await hubStub(env).timersChanged();
  } catch (e) {
    console.error("hub timersChanged failed", e);
  }
}
