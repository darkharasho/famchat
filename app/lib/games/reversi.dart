import 'package:flutter/foundation.dart';

import 'rules.dart';

/// Reversi. The first player is dark and moves first. Cells are `0..63`,
/// row-major with row 0 at the top. Move: `{"cell": 0..63}`; it must flip at
/// least one opposing disc. A side with no legal move is passed over, and the
/// game ends when neither side can move.
class ReversiBoard implements Board {
  ReversiBoard._(List<Side?> cells, this.lastCell, Side next)
    : _cells = List.unmodifiable(cells),
      _toMove = _resolve(cells, next).$1,
      _over = _resolve(cells, next).$2;

  factory ReversiBoard.initial() {
    final cells = List<Side?>.filled(size * size, null);
    cells[27] = Side.first;
    cells[36] = Side.first;
    cells[28] = Side.second;
    cells[35] = Side.second;
    return ReversiBoard._(cells, null, Side.first);
  }

  @visibleForTesting
  factory ReversiBoard.custom(Map<int, Side> discs, Side toMove) {
    final cells = List<Side?>.filled(size * size, null);
    discs.forEach((i, s) => cells[i] = s);
    return ReversiBoard._(cells, null, toMove);
  }

  static const size = 8;

  final List<Side?> _cells;
  final Side _toMove;
  final bool _over;

  /// The cell of the last disc placed, or null on a fresh board.
  final int? lastCell;

  /// The disc at [cell] (0..63), or null.
  Side? at(int cell) => _cells[cell];

  static const _dirs = [
    (-1, -1),
    (-1, 0),
    (-1, 1),
    (0, -1),
    (0, 1),
    (1, -1),
    (1, 0),
    (1, 1),
  ];

  /// The cells [side] would flip by playing [cell]; empty if illegal.
  static List<int> _flips(List<Side?> c, int cell, Side side) {
    if (c[cell] != null) return const [];
    final opp = side.other;
    final out = <int>[];
    for (final (dr, dc) in _dirs) {
      final line = <int>[];
      var r = cell ~/ size + dr, col = cell % size + dc;
      while (r >= 0 && r < size && col >= 0 && col < size) {
        final s = c[r * size + col];
        if (s == opp) {
          line.add(r * size + col);
        } else {
          if (s == side) out.addAll(line);
          break;
        }
        r += dr;
        col += dc;
      }
    }
    return out;
  }

  static bool _hasMove(List<Side?> c, Side side) {
    for (var i = 0; i < size * size; i++) {
      if (_flips(c, i, side).isNotEmpty) return true;
    }
    return false;
  }

  /// Who moves from [cells] when [next] is due: [next], else the other side if
  /// only they can move, else nobody (the game is over).
  static (Side, bool) _resolve(List<Side?> cells, Side next) {
    if (_hasMove(cells, next)) return (next, false);
    if (_hasMove(cells, next.other)) return (next.other, false);
    return (next, true);
  }

  /// The cells where [toMove] may play.
  List<int> legalCells() => _over
      ? const []
      : [
          for (var i = 0; i < size * size; i++)
            if (_flips(_cells, i, _toMove).isNotEmpty) i,
        ];

  /// Disc counts as (first, second).
  (int, int) get counts => (
    _cells.where((c) => c == Side.first).length,
    _cells.where((c) => c == Side.second).length,
  );

  @override
  Side get toMove => _toMove;

  @override
  Outcome? get outcome {
    if (!_over) return null;
    final (a, b) = counts;
    return Outcome(a == b ? null : (a > b ? Side.first : Side.second), 'discs');
  }

  @override
  bool get drawOffers => false;

  @override
  Board? play(Map<String, Object?> move) {
    final cell = move['cell'];
    if (cell is! int || cell < 0 || cell >= size * size) return null;
    if (_over) return null;
    final flips = _flips(_cells, cell, _toMove);
    if (flips.isEmpty) return null;
    final next = List<Side?>.of(_cells);
    next[cell] = _toMove;
    for (final f in flips) {
      next[f] = _toMove;
    }
    return ReversiBoard._(next, cell, _toMove.other);
  }
}
