export type MessageRow = {
  chat_id: string;
  seq: number;
  id: string;
  sender_user_id: string;
  sender_device_id: string;
  envelope: string;
  created_at: number;
  /** The disappearing timer it was stored with (seconds), or null. */
  disappear_secs?: number | null;
};

export function messageOut(r: MessageRow) {
  return {
    chatId: r.chat_id,
    seq: r.seq,
    id: r.id,
    senderUserId: r.sender_user_id,
    senderDeviceId: r.sender_device_id,
    envelope: JSON.parse(r.envelope) as unknown,
    createdAt: r.created_at,
    ...(r.disappear_secs ? { disappearSecs: r.disappear_secs } : {}),
  };
}
