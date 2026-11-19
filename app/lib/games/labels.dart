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
      'poke' => '👉 Poked in ${game.title}',
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
    case 'poke':
      return '👉 Poked you · your turn in $title';
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
  // An extra turn (a box closed, or the opponent passed): still the sender's.
  if (outcome == null && after.toMoveUserId == m.senderUserId) {
    return '♟ Moved in $title';
  }
  if (outcome == null) return '♟ Your turn in $title';
  final winner = after.winnerUserId;
  if (winner == null) return '🤝 Draw in $title';
  // In Reversi and Dots and Boxes the loser can make the final move.
  return winner == m.senderUserId
      ? '♟ You lost at $title'
      : '🏆 You won at $title';
}

/// The game a timeline event [m] belongs to and what it says, with [who] as the actor ("You" or a name):
/// resigns and draw offers, accepts and declines. Null for plays and pokes (see [gameEventsOf]) and anything else.
({String gameId, String text})? gameEventOf(MessageRow m, String who) {
  if (m.kind != 'move') return null;
  final p = _decode(m);
  if (p is! MoveBody) return null;
  final title = p.game.title;
  final text = switch (p.action['type']) {
    'resign' => '🏳 $who resigned at $title',
    'draw_offer' => '🤝 $who offered a draw in $title',
    'draw_accept' => '🤝 $who accepted a draw in $title',
    'draw_decline' => '$who declined a draw in $title',
    _ => null,
  };
  return text == null ? null : (gameId: p.target, text: text);
}

/// A game line in the timeline: [text], then [suffix] in bold (" · Your turn"), drawn tinted when [poke].
typedef GameEvent = ({String gameId, String text, String? suffix, bool poke});

/// The game lines for a chat's [messages] (oldest first), by message id: resigns and draw offers
/// ([gameEventOf]), pokes, and plays the rules applied ([plays], from [playResults]). [games] are the
/// chat's games now, [nameOf] gives "You" for [me] or a first name, and [shown] says whether a row
/// that isn't a game line is drawn in the timeline.
///
/// A run of play lines for one game with nothing else drawn between them keeps only its newest. The
/// newest play line of an unfinished game where it's [me]'s turn says " · Your turn", unless the chat
/// is [readOnly].
Map<String, GameEvent> gameEventsOf(
  List<MessageRow> messages, {
  required Map<String, GameState> plays,
  required List<GameState> games,
  required String? me,
  required String Function(String userId) nameOf,
  required bool Function(MessageRow m) shown,
  bool readOnly = false,
}) {
  final byGame = {for (final g in games) g.id: g};
  final out = <String, GameEvent>{};
  final playIds = <String>{};
  // The drawn rows in order: (id, game id of a play line or null).
  final drawn = <(String, String?)>[];
  for (final m in messages) {
    if (m.kind != 'move') {
      if (shown(m)) drawn.add((m.id, null));
      continue;
    }
    final p = _decode(m);
    if (p is! MoveBody) continue;
    final title = p.game.title;
    GameEvent? e;
    switch (p.action['type']) {
      case 'play':
        final after = plays[m.id];
        if (after == null) break;
        final String text;
        if (!after.over) {
          text = '♟ ${nameOf(m.senderUserId)} moved in $title';
        } else {
          final winner = after.winnerUserId;
          text = winner == null
              ? '🤝 Draw in $title'
              : '🏆 ${nameOf(winner)} won $title';
        }
        e = (gameId: p.target, text: text, suffix: null, poke: false);
        playIds.add(m.id);
      case 'poke':
        final g = byGame[p.target];
        if (g == null) break;
        final sender = m.senderUserId;
        final other = sender == g.firstUserId ? g.secondUserId : g.firstUserId;
        final text = sender == me
            ? '👉 You poked ${nameOf(other)} · $title'
            : other == me
            ? '👉 ${nameOf(sender)} poked you · Your turn in $title'
            : '👉 ${nameOf(sender)} poked ${nameOf(other)} · $title';
        e = (gameId: p.target, text: text, suffix: null, poke: true);
      default:
        final r = gameEventOf(m, nameOf(m.senderUserId));
        if (r != null) {
          e = (gameId: r.gameId, text: r.text, suffix: null, poke: false);
        }
    }
    if (e == null) continue;
    out[m.id] = e;
    drawn.add((m.id, playIds.contains(m.id) ? e.gameId : null));
  }
  // Collapse: a play line followed directly by a play line of the same game goes.
  for (var i = 0; i + 1 < drawn.length; i++) {
    final game = drawn[i].$2;
    if (game != null && drawn[i + 1].$2 == game) out.remove(drawn[i].$1);
  }
  if (me != null && !readOnly) {
    final waiting = {
      for (final g in games)
        if (g.toMoveUserId == me) g.id,
    };
    for (final (id, game) in drawn.reversed) {
      if (game == null || !waiting.remove(game)) continue;
      final e = out[id]!;
      out[id] = (
        gameId: e.gameId,
        text: e.text,
        suffix: ' · Your turn',
        poke: false,
      );
    }
  }
  return out;
}

/// When [me] last poked in game [gameId] (Unix ms, from the message rows so every device agrees), or null.
int? lastPokeAt(List<MessageRow> rows, String gameId, String me) {
  int? last;
  for (final m in rows) {
    if (m.kind != 'move' ||
        m.senderUserId != me ||
        m.targetId != gameId ||
        m.state == 'failed') {
      continue;
    }
    final p = _decode(m);
    if (p is! MoveBody || p.target != gameId || p.action['type'] != 'poke') {
      continue;
    }
    if (last == null || m.createdAt > last) last = m.createdAt;
  }
  return last;
}
