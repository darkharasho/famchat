import 'checkers.dart';
import 'chess_board.dart';
import 'dots_and_boxes.dart';
import 'four_in_a_row.dart';
import 'reversi.dart';
import 'tictactoe.dart';

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
  dotsandboxes('dotsandboxes', 'Dots and Boxes');

  const GameType(this.wire, this.title);

  final String wire, title;

  static GameType? fromWire(String s) {
    for (final t in values) {
      if (t.wire == s) return t;
    }
    return null;
  }
}

/// [winner] null means a draw. [reason] is one of 'line', 'full', 'no_moves',
/// 'checkmate', 'stalemate', 'discs', 'boxes', 'threefold', 'fifty_moves',
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

Board initialBoard(GameType t) {
  switch (t) {
    case GameType.tictactoe:
      return TicTacToeBoard.initial();
    case GameType.checkers:
      return CheckersBoard.initial();
    case GameType.chess:
      return ChessBoard.initial();
    case GameType.fourinarow:
      return FourInARowBoard.initial();
    case GameType.reversi:
      return ReversiBoard.initial();
    case GameType.dotsandboxes:
      return DotsAndBoxesBoard.initial();
  }
}
