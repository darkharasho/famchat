import 'checkers.dart';
import 'chess_board.dart';
import 'dots_and_boxes.dart';
import 'four_in_a_row.dart';
import 'go_fish.dart';
import 'landlord/landlord.dart';
import 'reversi.dart';
import 'tictactoe.dart';
import 'war.dart';

/// An integer read from decoded JSON: an int, or an integral finite double
/// within ±2^53 (`3.0` → 3); null for anything else. On the web `3.0 is int`
/// but not natively, so every platform must read wire numbers through this to
/// agree on which moves are valid.
int? wireInt(Object? v) {
  if (v is! num || !v.isFinite || v.abs() > 9007199254740991) return null;
  final i = v.toInt();
  return i == v ? i : null;
}

enum Side {
  first,
  second;

  Side get other => this == Side.first ? Side.second : Side.first;
}

enum GameType {
  tictactoe('tictactoe', 'Tic-tac-toe'),
  checkers('checkers', 'Checkers'),
  chess('chess', 'Chess'),
  fourinarow('fourinarow', 'Four in a Row'),
  reversi('reversi', 'Reversi'),
  dotsandboxes('dotsandboxes', 'Dots and Boxes'),
  gofish('gofish', 'Go Fish'),
  war('war', 'War'),
  landlord('landlord', 'Landlord');

  const GameType(this.wire, this.title);

  final String wire, title;

  /// Whether the game needs the `game` message's `seed` (it shuffles or
  /// rolls). Without a valid seed such a game is inert.
  bool get seeded => this == gofish || this == war || this == landlord;

  /// Long games (days) get their own slot: a DM can run one long and one
  /// quick game at once.
  bool get long => this == landlord;

  /// This app's version of the game's rules. Every move carries its sender's,
  /// so a phone with older rules (which would replay the same moves to a
  /// different position) knows to update instead of going out of sync. Bump it
  /// whenever a change makes the same moves play out differently.
  /// Landlord: 2 tax goes into the Rest Stop pot; 3 bail and card payments
  /// too; 4 the bank never runs out of houses or hotels. War: 2 the whole-deck
  /// mode.
  int get rules => switch (this) {
    landlord => 4,
    war => 2,
    _ => 1,
  };

  static GameType? fromWire(String s) {
    for (final t in values) {
      if (t.wire == s) return t;
    }
    return null;
  }
}

/// [winner] null means a draw. [reason] is one of 'line', 'full', 'no_moves',
/// 'checkmate', 'stalemate', 'discs', 'boxes', 'books', 'cards', 'bankrupt', 'threefold', 'fifty_moves',
/// 'insufficient', 'resigned' or 'agreed'.
class Outcome {
  const Outcome(this.winner, this.reason);

  final Side? winner;
  final String reason;
}

/// An immutable game position. Positions on two phones are replayed from
/// messages and must agree, so [play] is pure.
abstract class Board {
  Side get toMove;

  /// From the position only (not resign/agreed).
  Outcome? get outcome;

  /// Returns the new position, or null if the move is malformed or illegal.
  /// Never throws and never mutates this board.
  Board? play(Map<String, Object?> move);

  /// Whether players may offer draws (false for tic-tac-toe).
  bool get drawOffers;
}

/// The starting position of [t]. [seed] is the `game` message's seed, used
/// by [GameType.seeded] games (a missing one deals from 0; such games are
/// inert anyway). [optionalJumps] is checkers' house rule and [wholeDeck]
/// War's (each ignored by other games).
Board initialBoard(
  GameType t, [
  int? seed,
  bool optionalJumps = false,
  bool wholeDeck = false,
]) {
  switch (t) {
    case GameType.tictactoe:
      return TicTacToeBoard.initial();
    case GameType.checkers:
      return CheckersBoard.initial(optionalJumps: optionalJumps);
    case GameType.chess:
      return ChessBoard.initial();
    case GameType.fourinarow:
      return FourInARowBoard.initial();
    case GameType.reversi:
      return ReversiBoard.initial();
    case GameType.dotsandboxes:
      return DotsAndBoxesBoard.initial();
    case GameType.gofish:
      return GoFishBoard.deal(seed ?? 0);
    case GameType.war:
      return WarBoard.deal(seed ?? 0, wholeDeck: wholeDeck);
    case GameType.landlord:
      return LandlordBoard.setup(seed ?? 0);
  }
}
