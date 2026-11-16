/** [userId] and everyone who shares a chat with them: who hears about that user's devices. */
export async function sharingUserIds(db: D1Database, userId: string): Promise<string[]> {
  const { results } = await db.prepare(
    `SELECT DISTINCT user_id FROM chat_members
     WHERE chat_id IN (SELECT chat_id FROM chat_members WHERE user_id = ?)`,
  ).bind(userId).all<{ user_id: string }>();
  return [...new Set([userId, ...results.map((r) => r.user_id)])];
}
