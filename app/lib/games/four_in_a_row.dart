import 'rules.dart';

/// Four in a Row. First is red and moves first; a disc falls to the lowest
/// empty cell of its column. Move: `{"col": 0..6}`.
class FourInARowBoard implements Board {
  FourInARowBoard._(List<Side?> cells, this.lastCol)
    : _cells = List.unmodifiable(cells),
      winningLine = _findLine(cells);

  factory FourInARowBoard.initial() =>
      FourInARowBoard._(List<Side?>.filled(columns * rows, null), null);

  static const columns = 7, rows = 6;

  /// Index `col * rows + row`, row 0 at the bottom.
  final List<Side?> _cells;

  /// The four winning cells as (col, row), or null if nobody has a line.
  final List<(int, int)>? winningLine;

  /// The column of the last disc dropped, or null on a fresh board.
  final int? lastCol;

  /// The disc at [col] (0 at the left) and [row] (0 at the bottom), or null.
  Side? at(int col, int row) => _cells[col * rows + row];

  static const _dirs = [(1, 0), (0, 1), (1, 1), (1, -1)];

  static List<(int, int)>? _findLine(List<Side?> c) {
    for (var col = 0; col < columns; col++) {
      for (var row = 0; row < rows; row++) {
        final s = c[col * rows + row];
        if (s == null) continue;
        for (final (dc, dr) in _dirs) {
          final line = <(int, int)>[];
          for (var k = 0; k < 4; k++) {
            final cc = col + dc * k, rr = row + dr * k;
            if (cc < 0 || cc >= columns || rr < 0 || rr >= rows) break;
            if (c[cc * rows + rr] != s) break;
            line.add((cc, rr));
          }
          if (line.length == 4) return line;
        }
      }
    }
    return null;
  }

  int get _count => _cells.where((c) => c != null).length;

  @override
  Side get toMove => _count.isEven ? Side.first : Side.second;

  @override
  Outcome? get outcome {
    final line = winningLine;
    if (line != null) return Outcome(at(line[0].$1, line[0].$2), 'line');
    if (_count == columns * rows) return const Outcome(null, 'full');
    return null;
  }

  @override
  bool get drawOffers => false;

  @override
  Board? play(Map<String, Object?> move) {
    final col = move['col'];
    if (col is! int || col < 0 || col >= columns) return null;
    if (outcome != null) return null;
    var row = 0;
    while (row < rows && at(col, row) != null) {
      row++;
    }
    if (row == rows) return null;
    final next = List<Side?>.of(_cells);
    next[col * rows + row] = toMove;
    return FourInARowBoard._(next, col);
  }
}
