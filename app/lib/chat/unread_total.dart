// The total unread count across chats that aren't muted: what the app-icon badge shows. The server
// counts the same way for the badge it puts in pushes (server/src/push/consumer.ts unreadTotals),
// except for deleted messages, which only the app can see. Platform-neutral: phones set their icon
// badge from it (lib/push/app_badge.dart); desktops can too.
import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'db/chat_db.dart';
import 'providers.dart';

/// Whether [chat] is muted at [now] (`mutedUntil` set and still ahead).
bool chatMutedAt(ChatRow chat, DateTime now) => (chat.mutedUntil ?? 0) > now.millisecondsSinceEpoch;

/// The sum of [items]' unread counts, leaving out chats muted at [now].
int unreadTotal(Iterable<ChatListItem> items, DateTime now) =>
    items.where((i) => !chatMutedAt(i.chat, now)).fold(0, (n, i) => n + i.unread);

/// The total unread count across unmuted chats; 0 until the chat list has loaded. Recounts when the
/// chat list changes and when the soonest mute ends.
final unreadTotalProvider = Provider<int>((ref) {
  final items = ref.watch(chatListProvider).value ?? const <ChatListItem>[];
  final now = clock.now();
  final ms = now.millisecondsSinceEpoch;
  final ends = [
    for (final i in items)
      if ((i.chat.mutedUntil ?? 0) > ms) i.chat.mutedUntil!,
  ];
  if (ends.isNotEmpty) {
    final soonest = ends.reduce((a, b) => a < b ? a : b);
    // Browsers overflow timer delays past about 24 days (mutes can be "forever"): recheck daily.
    final wait = Duration(milliseconds: (soonest - ms).clamp(0, const Duration(days: 1).inMilliseconds) + 1);
    final timer = Timer(wait, ref.invalidateSelf);
    ref.onDispose(timer.cancel);
  }
  return unreadTotal(items, now);
});
