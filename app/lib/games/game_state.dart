// Game state is a pure replay of a chat's stored `game` and `move` messages
// in server seq order, so every device derives the same positions.
import 'dart:convert';

import '../chat/db/chat_db.dart';
import '../chat/plaintext.dart';
import 'rules.dart';

class GameState {
  const GameState({
    required this.id,
    required this.type,
    required this.firstUserId,
    required this.secondUserId,
    required this.board,
    required this.ply,
    required this.outcome,
    required this.drawOfferedBy,
    required this.inert,
    required this.startedSeq,
  });

  /// The game message's id.
  final String id;
  final GameType type;
  final String firstUserId, secondUserId;
  final Board board;

  /// The ply the next play must carry.
  final int ply;

  /// The board's outcome, or a resignation or agreed draw.
  final Outcome? outcome;

  /// The player with a pending draw offer.
  final String? drawOfferedBy;

  /// Never started: another game was running, or the chat isn't two people.
  final bool inert;
  final int? startedSeq;

  bool get over => outcome != null;

  /// Null when over or inert.
  String? get toMoveUserId => over || inert ? null : _userOf(board.toMove);

  Side? sideOf(String userId) => userId == firstUserId
      ? Side.first
      : userId == secondUserId
      ? Side.second
      : null;

  /// Null for a draw or an unfinished game.
  String? get winnerUserId {
    final w = outcome?.winner;
    return w == null ? null : _userOf(w);
  }

  String _userOf(Side s) => s == Side.first ? firstUserId : secondUserId;
}

/// [rows] as `watchMessages` orders them (seq ascending, pending last).
/// [memberIds] the chat's members. Games come out in the order of their rows.
List<GameState> deriveGames(List<MessageRow> rows, List<String> memberIds) {
  final games = <_Game>[];
  final byId = <String, _Game>{};
  for (final r in rows) {
    if (r.state == 'failed') continue;
    if (r.kind == 'game') {
      final body = _decode(r);
      if (body is! GameBody || byId.containsKey(r.id)) continue;
      final second = memberIds.where((m) => m != body.first).firstOrNull;
      final inert =
          memberIds.length != 2 ||
          !memberIds.contains(body.first) ||
          second == null ||
          games.any((g) => !g.inert && g.outcome == null);
      final g = _Game(r.id, body.game, body.first, second ?? '', inert, r.seq);
      games.add(g);
      byId[r.id] = g;
    } else if (r.kind == 'move') {
      final body = _decode(r);
      if (body is! MoveBody) continue;
      byId[body.target]?.apply(r.senderUserId, body);
    }
  }
  return [for (final g in games) g.freeze()];
}

/// The unfinished, non-inert game, if any.
GameState? activeGame(List<GameState> games) =>
    games.where((g) => !g.inert && !g.over).firstOrNull;

Plaintext? _decode(MessageRow r) {
  final body = r.body;
  if (body == null) return null;
  try {
    return Plaintext.decode(utf8.encode(body));
  } on FormatException {
    return null;
  }
}

class _Game {
  _Game(
    this.id,
    this.type,
    this.first,
    this.second,
    this.inert,
    this.startedSeq,
  ) : board = initialBoard(type);

  final String id;
  final GameType type;
  final String first, second;
  final bool inert;
  final int? startedSeq;
  Board board;
  int ply = 0;
  Outcome? outcome;
  String? drawOfferedBy;

  void apply(String sender, MoveBody m) {
    if (inert || outcome != null || m.game != type || m.ply != ply) return;
    final Side side;
    if (sender == first) {
      side = Side.first;
    } else if (sender == second) {
      side = Side.second;
    } else {
      return;
    }
    final other = side == Side.first ? second : first;
    switch (m.action['type']) {
      case 'play':
        if (board.toMove != side) return;
        final next = board.play({...m.action}..remove('type'));
        if (next == null) return;
        board = next;
        ply++;
        drawOfferedBy = null;
        outcome = next.outcome;
      case 'resign':
        outcome = Outcome(side.other, 'resigned');
      case 'draw_offer':
        if (board.drawOffers) drawOfferedBy = sender;
      case 'draw_accept':
        if (drawOfferedBy == other) outcome = const Outcome(null, 'agreed');
      case 'draw_decline':
        if (drawOfferedBy == other) drawOfferedBy = null;
    }
  }

  GameState freeze() => GameState(
    id: id,
    type: type,
    firstUserId: first,
    secondUserId: second,
    board: board,
    ply: ply,
    outcome: outcome,
    drawOfferedBy: drawOfferedBy,
    inert: inert,
    startedSeq: startedSeq,
  );
}
