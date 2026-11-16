import type { Env } from "./env";

/** Sends a hub event to every open socket of [userIds]. Never throws: events are hints, REST is the truth. */
export async function notify(_env: Env, _userIds: string[], _event: Record<string, unknown>): Promise<void> {
  // Wired to the FamilyHub Durable Object in a later task.
}
