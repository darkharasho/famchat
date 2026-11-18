import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../chat/providers.dart';
import 'game_state.dart';

/// A chat's games, replayed from its messages; empty while either stream is
/// still loading.
final gamesProvider = Provider.family<List<GameState>, String>((ref, chatId) {
  final rows = ref.watch(messagesProvider(chatId)).value;
  final members = ref.watch(membersProvider(chatId)).value;
  if (rows == null || members == null) return const [];
  return deriveGames(rows, [for (final m in members) m.userId]);
});
