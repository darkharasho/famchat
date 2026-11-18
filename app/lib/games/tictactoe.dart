import 'rules.dart';

const _lines = [
  [0, 1, 2],
  [3, 4, 5],
  [6, 7, 8],
  [0, 3, 6],
  [1, 4, 7],
  [2, 5, 8],
  [0, 4, 8],
  [2, 4, 6],
];

/// Tic-tac-toe. First is X and moves first. Move: `{"cell": 0..8}`.
class TicTacToeBoard implements Board {
  TicTacToeBoard._(List<Side?> cells)
    : _cells = List.unmodifiable(cells),
      winningLine = _findLine(cells);

  factory TicTacToeBoard.initial() =>
      TicTacToeBoard._(List<Side?>.filled(9, null));

  final List<Side?> _cells;

  /// 9 cells, row-major.
  List<Side?> get cells => _cells;

  /// The three winning cell indexes, or null if nobody has a line.
  final List<int>? winningLine;

  static List<int>? _findLine(List<Side?> c) {
    for (final l in _lines) {
      final s = c[l[0]];
      if (s != null && c[l[1]] == s && c[l[2]] == s) return l;
    }
    return null;
  }

  @override
  Side get toMove {
    final filled = _cells.where((c) => c != null).length;
    return filled.isEven ? Side.first : Side.second;
  }

  @override
  Outcome? get outcome {
    final line = winningLine;
    if (line != null) return Outcome(_cells[line[0]], 'line');
    if (_cells.every((c) => c != null)) return const Outcome(null, 'full');
    return null;
  }

  @override
  bool get drawOffers => false;

  @override
  Board? play(Map<String, Object?> move) {
    final cell = wireInt(move['cell']);
    if (cell == null || cell < 0 || cell > 8) return null;
    if (outcome != null || _cells[cell] != null) return null;
    final next = List<Side?>.of(_cells);
    next[cell] = toMove;
    return TicTacToeBoard._(next);
  }
}
