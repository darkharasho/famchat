import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:meta/meta.dart';

import '../chat/providers.dart';
import 'game_state.dart';

/// Per chat: replay work [gamesProvider] reuses across rebuilds.
@visibleForTesting
final gameCacheProvider = Provider.family<GameCache, String>(
  (ref, chatId) => GameCache(),
);

/// A chat's games, replayed from its messages; empty while the chat, its
/// messages or its members are still loading. Only the chat's kind matters,
/// so drafts and read positions don't trigger a replay, and games whose rows
/// didn't change aren't replayed (see [GameCache]).
final gamesProvider = Provider.family<List<GameState>, String>((ref, chatId) {
  final kind = ref.watch(chatProvider(chatId).select((c) => c.value?.kind));
  final rows = ref.watch(messagesProvider(chatId)).value;
  final members = ref.watch(membersProvider(chatId)).value;
  if (kind == null || rows == null || members == null) return const [];
  return ref.watch(gameCacheProvider(chatId)).derive(rows, [
    for (final m in members) m.userId,
  ], direct: kind == 'direct');
});

/// A chat's plays the rules applied: move id → the game's state right after it
/// (see [playResults]). Empty while loading, like [gamesProvider].
final gamePlaysProvider = Provider.family<Map<String, GameState>, String>((ref, chatId) {
  final kind = ref.watch(chatProvider(chatId).select((c) => c.value?.kind));
  final rows = ref.watch(messagesProvider(chatId)).value;
  final members = ref.watch(membersProvider(chatId)).value;
  if (kind == null || rows == null || members == null) return const {};
  return playResults(rows, [
    for (final m in members) m.userId,
  ], direct: kind == 'direct');
});
