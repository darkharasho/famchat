// One-line labels for game and move messages, for the chat list and notification previews.
import 'dart:convert';

import '../chat/db/chat_db.dart';
import '../chat/plaintext.dart';
import 'game_state.dart';

Plaintext? _decode(MessageRow m) {
  final body = m.body;
  if (body == null) return null;
  try {
    return Plaintext.decode(utf8.encode(body));
  } catch (_) {
    return null;
  }
}

/// A state-free label for a `game` or `move` message, or null for any other kind or an unreadable body.
String? gameListLabel(MessageRow m) {
  if (m.kind != 'game' && m.kind != 'move') return null;
  final p = _decode(m);
  return switch (p) {
    GameBody(:final game) => '🎲 Started a game of ${game.title}',
    MoveBody(:final game, :final action) => switch (action['type']) {
      'play' => '♟ Moved in ${game.title}',
      'resign' => '🏳 Resigned at ${game.title}',
      'draw_offer' => '🤝 Offered a draw in ${game.title}',
      'draw_accept' => '🤝 Accepted a draw in ${game.title}',
      'draw_decline' => 'Declined a draw in ${game.title}',
      _ => null,
    },
    _ => null,
  };
}

/// The push label for an incoming game or move [m] sent by someone else, using the stored game and its moves.
Future<String?> gamePushLabel(ChatDb db, String chatId, MessageRow m) async {
  final p = _decode(m);
  if (p is GameBody) return '🎲 Started a game of ${p.game.title}';
  if (p is! MoveBody) return null;
  final title = p.game.title;
  switch (p.action['type']) {
    case 'resign':
      return '🏳 Resigned at $title';
    case 'draw_offer':
      return '🤝 Offered a draw in $title';
    case 'draw_accept':
      return '🤝 Draw in $title';
    case 'draw_decline':
      return 'Declined a draw in $title';
    case 'play':
      break;
    default:
      return null;
  }
  final game = await db.messageById(p.target);
  if (game == null || game.chatId != chatId) return '♟ Moved in $title';
  final chat = await db.chatById(chatId);
  final members = [for (final r in await db.membersOf(chatId)) r.userId];
  final changes = [
    for (final r in await db.changesTo(chatId, p.target))
      if (r.id != m.id) r,
  ];
  GameState? stateOf(List<MessageRow> rows) => deriveGames(
    rows,
    members,
    direct: chat?.kind == 'direct',
  ).where((g) => g.id == game.id).firstOrNull;
  final after = stateOf([game, ...changes, m]);
  final before = stateOf([game, ...changes]);
  // A play the rules ignored leaves the state unchanged.
  if (after == null || before == null || after.ply == before.ply) {
    return '♟ Moved in $title';
  }
  final outcome = after.outcome;
  if (outcome == null) return '♟ Your turn in $title';
  return outcome.winner == null ? '🤝 Draw in $title' : '♟ You lost at $title';
}
