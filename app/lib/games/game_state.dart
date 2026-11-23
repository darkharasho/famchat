// Game state is a pure replay of a chat's stored `game` and `move` messages
// in server seq order, so every device derives the same positions.
import 'dart:convert';

import 'package:meta/meta.dart';

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
    this.outOfSync = false,
    this.behindUserId,
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

  /// This device can't follow the game: a move came with newer rules
  /// ([GameType.rules]), or the newest play at the current ply was refused
  /// (the sender's device has different rules). Until an update, nobody can
  /// move here.
  final bool outOfSync;

  /// The player whose newest move has older rules than this app's: their
  /// device may go out of sync until they update. Null if none (or unknown).
  final String? behindUserId;

  bool get over => outcome != null;

  /// Null when over, inert or [outOfSync].
  String? get toMoveUserId => over || inert || outOfSync ? null : _userOf(board.toMove);

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
/// Games only run in direct chats: when [direct] is false every game is inert.
List<GameState> deriveGames(
  List<MessageRow> rows,
  List<String> memberIds, {
  bool direct = true,
}) => _walk(rows, memberIds, direct, null);

/// Move row id → its game's state right after that `play`, for every play in
/// [rows] the rules applied (a stale, illegal or out-of-turn play, or one in an
/// inert or finished game, has no entry). Same input as [deriveGames].
Map<String, GameState> playResults(
  List<MessageRow> rows,
  List<String> memberIds, {
  bool direct = true,
}) {
  final out = <String, GameState>{};
  _walk(rows, memberIds, direct, (r, g, plyBefore) {
    if (g.ply != plyBefore) out[r.id] = g.freeze();
  });
  return out;
}

List<GameState> _walk(
  List<MessageRow> rows,
  List<String> memberIds,
  bool direct,
  void Function(MessageRow row, _Game game, int plyBefore)? onMove,
) {
  final games = <_Game>[];
  final byId = <String, _Game>{};
  for (final r in rows) {
    if (r.state == 'failed') continue;
    if (r.kind == 'game') {
      final body = _decode(r);
      if (body is! GameBody || byId.containsKey(r.id)) continue;
      final second = memberIds.where((m) => m != body.first).firstOrNull;
      final inert =
          !direct ||
          memberIds.length != 2 ||
          !memberIds.contains(body.first) ||
          second == null ||
          (body.game.seeded && body.seed == null) ||
          games.any((g) => !g.inert && g.outcome == null && g.type.long == body.game.long);
      final g = _Game(r.id, body.game, body.first, second ?? '', inert, r.seq, body.seed, body.optionalJumps, body.wholeDeck, body.twosBeatAces);
      games.add(g);
      byId[r.id] = g;
    } else if (r.kind == 'move') {
      final body = _decode(r);
      if (body is! MoveBody) continue;
      final g = byId[body.target];
      if (g == null) continue;
      final ply = g.ply;
      g.apply(r.senderUserId, body);
      onMove?.call(r, g, ply);
    }
  }
  return [for (final g in games) g.freeze()];
}

/// [deriveGames] for one chat, reusing work across emissions of the same
/// chat's rows: a game whose inputs (its `game` row, its players, whether it
/// is inert, and its `move` rows in order) are unchanged keeps its
/// [GameState] object, and a game whose move rows only grew at the end
/// resumes from where it stopped instead of replaying from the start. The
/// result always equals a fresh [deriveGames] over the same input.
class GameCache {
  final _entries = <String, _Entry>{};
  List<GameState> _last = const [];

  /// How many times [derive] ran; for tests.
  @visibleForTesting
  int derives = 0;

  /// How many move rows were applied to boards; for tests.
  @visibleForTesting
  int applied = 0;

  List<GameState> derive(
    List<MessageRow> rows,
    List<String> memberIds, {
    bool direct = true,
  }) {
    derives++;
    // The same walk as [deriveGames]: a move counts toward a game only when
    // it comes after that game's row.
    final slots = <_Slot>[];
    final byId = <String, _Slot>{};
    for (var i = 0; i < rows.length; i++) {
      final r = rows[i];
      if (r.state == 'failed') continue;
      if (r.kind == 'game') {
        final body = _decode(r);
        if (body is! GameBody || byId.containsKey(r.id)) continue;
        final s = _Slot(r, body, i);
        slots.add(s);
        byId[r.id] = s;
      } else if (r.kind == 'move') {
        final body = _decode(r);
        if (body is! MoveBody) continue;
        byId[body.target]?.moves.add((r, body, i));
      }
    }
    final done = <(_Slot, _Entry)>[];
    for (final s in slots) {
      final first = s.body.first;
      final second = memberIds.where((m) => m != first).firstOrNull;
      // As in [deriveGames]: inert if another game was running when this
      // game's row came, i.e. not inert and not ended by a move before it.
      final inert =
          !direct ||
          memberIds.length != 2 ||
          !memberIds.contains(first) ||
          second == null ||
          (s.body.game.seeded && s.body.seed == null) ||
          done.any(
            (d) =>
                !d.$2.game.inert &&
                d.$2.game.type.long == s.body.game.long &&
                !_endedBefore(d, s.pos),
          );
      done.add((s, _entryFor(s, second ?? '', inert)));
    }
    _entries
      ..clear()
      ..addEntries([for (final d in done) MapEntry(d.$1.row.id, d.$2)]);
    final out = [for (final d in done) d.$2.state];
    if (out.length == _last.length &&
        Iterable.generate(out.length)
            .every((i) => identical(out[i], _last[i]))) {
      return _last;
    }
    return _last = out;
  }

  static bool _endedBefore((_Slot, _Entry) d, int pos) {
    final end = d.$2.end;
    return end != null && d.$1.moves[end].$3 < pos;
  }

  _Entry _entryFor(_Slot s, String second, bool inert) {
    final r = s.row;
    final moves = [
      for (final m in s.moves) (m.$1.id, m.$1.senderUserId, m.$1.body),
    ];
    final old = _entries[r.id];
    final _Game g;
    int? end;
    var from = 0;
    if (old != null &&
        old.body == r.body &&
        old.game.type == s.body.game &&
        old.game.second == second &&
        old.game.inert == inert &&
        old.moves.length <= moves.length &&
        Iterable.generate(old.moves.length)
            .every((i) => old.moves[i] == moves[i])) {
      if (old.moves.length == moves.length && old.state.startedSeq == r.seq) {
        return old;
      }
      g = old.game;
      end = old.end;
      from = old.moves.length;
    } else {
      g = _Game(r.id, s.body.game, s.body.first, second, inert, r.seq, s.body.seed, s.body.optionalJumps, s.body.wholeDeck, s.body.twosBeatAces);
    }
    for (var i = from; i < moves.length; i++) {
      applied++;
      g.apply(moves[i].$2, s.moves[i].$2);
      if (end == null && g.outcome != null) end = i;
    }
    g.startedSeq = r.seq;
    return _Entry(r.body, g, moves, end, g.freeze());
  }
}

class _Slot {
  _Slot(this.row, this.body, this.pos);

  final MessageRow row;
  final GameBody body;

  /// Index in the derive's rows.
  final int pos;

  /// (row, body, index in rows) of this game's moves, in order.
  final moves = <(MessageRow, MoveBody, int)>[];
}

class _Entry {
  _Entry(this.body, this.game, this.moves, this.end, this.state);

  /// The game row's body.
  final String? body;

  /// Advanced through [moves]. Only the newest entry for a game is kept, so
  /// resuming it in place is safe.
  final _Game game;

  /// (id, sender, body) of the moves applied, in order. A move's seq and
  /// state don't change what it does, so a pending move turning sent keeps
  /// the entry.
  final List<(String, String, String?)> moves;

  /// Index in [moves] of the move that ended the game.
  final int? end;

  final GameState state;
}

/// The unfinished, non-inert game of the long or quick kind, if any.
GameState? activeGame(List<GameState> games, {required bool long}) =>
    games.where((g) => !g.inert && !g.over && g.type.long == long).firstOrNull;

/// The unfinished games: the long one first, then the quick one.
List<GameState> activeGames(List<GameState> games) => [
  ?activeGame(games, long: true),
  ?activeGame(games, long: false),
];

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
    int? seed, [
    bool optionalJumps = false,
    bool wholeDeck = false,
    bool twosBeatAces = false,
  ]) : board = initialBoard(type, seed, optionalJumps, wholeDeck, twosBeatAces);

  final String id;
  final GameType type;
  final String first, second;
  final bool inert;
  int? startedSeq;
  Board board;
  int ply = 0;
  Outcome? outcome;
  String? drawOfferedBy;

  /// A move came with newer rules than this app's.
  bool newerRules = false;

  /// The newest play at the current ply was refused, and none applied since.
  bool refused = false;

  /// Each player's newest known [MoveBody.rules].
  final _rules = <String, int>{};

  void apply(String sender, MoveBody m) {
    if (inert || outcome != null || m.game != type) return;
    final Side side;
    if (sender == first) {
      side = Side.first;
    } else if (sender == second) {
      side = Side.second;
    } else {
      return;
    }
    if (m.rules case final r?) {
      _rules[sender] = r;
      if (r > type.rules) newerRules = true;
    }
    if (m.ply != ply) return;
    final other = side == Side.first ? second : first;
    switch (m.action['type']) {
      case 'play':
        if (board.toMove != side) return;
        final next = board.play({...m.action}..remove('type'));
        // Both devices had this position at this ply, so a refused play
        // means the sender's device has different rules.
        if (next == null) {
          refused = true;
          return;
        }
        refused = false;
        board = next;
        ply++;
        // A play by the offerer's opponent declines a pending offer.
        if (drawOfferedBy != sender) drawOfferedBy = null;
        outcome = next.outcome;
      case 'resign':
        outcome = Outcome(side.other, 'resigned');
      case 'draw_offer':
        if (board.drawOffers && drawOfferedBy == null) drawOfferedBy = sender;
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
    outOfSync: newerRules || refused,
    behindUserId: [first, second].where((u) => (_rules[u] ?? type.rules) < type.rules).firstOrNull,
  );
}
