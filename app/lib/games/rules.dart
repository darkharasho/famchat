import 'tictactoe.dart';

enum Side {
  first,
  second;

  Side get other => this == Side.first ? Side.second : Side.first;
}

enum GameType {
  tictactoe('tictactoe', 'Tic-tac-toe'),
  checkers('checkers', 'Checkers'),
  chess('chess', 'Chess');

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
/// 'checkmate', 'stalemate', 'threefold', 'fifty_moves', 'insufficient',
/// 'resigned' or 'agreed'.
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
      throw UnimplementedError('checkers');
    case GameType.chess:
      throw UnimplementedError('chess');
  }
}
