import 'package:meta/meta.dart';

import 'rules.dart';

enum CheckersPiece { man, king }

class CheckersSquare {
  const CheckersSquare(this.side, this.piece);

  final Side side;
  final CheckersPiece piece;
}

const _diagonals = [(-1, -1), (-1, 1), (1, -1), (1, 1)];

/// American checkers on the 32 dark squares. Square numbering is wire format:
/// `row = sq ~/ 4` (row 0 is first's back rank) and
/// `col = 2 * (sq % 4) + (row.isOdd ? 1 : 0)`. First's men start on 0–11 and
/// move toward higher rows; second's start on 20–31 and move toward lower
/// rows. Move: `{"path": [from, landing1, landing2, ...]}`.
///
/// Captures are mandatory and a jump sequence must continue while it can,
/// except that a man reaching the far row is crowned and the move ends.
class CheckersBoard implements Board {
  CheckersBoard._(List<CheckersSquare?> squares, this.toMove, this.lastPath)
    : _squares = List.unmodifiable(squares);

  factory CheckersBoard.initial() => CheckersBoard._(
    [
      for (var sq = 0; sq < 32; sq++)
        sq < 12
            ? const CheckersSquare(Side.first, CheckersPiece.man)
            : sq >= 20
            ? const CheckersSquare(Side.second, CheckersPiece.man)
            : null,
    ],
    Side.first,
    null,
  );

  @visibleForTesting
  factory CheckersBoard.custom(Map<int, CheckersSquare> pieces, Side toMove) =>
      CheckersBoard._(
        [for (var sq = 0; sq < 32; sq++) pieces[sq]],
        toMove,
        null,
      );

  final List<CheckersSquare?> _squares;

  @override
  final Side toMove;

  /// The path of the move that produced this board; null on a fresh board.
  final List<int>? lastPath;

  static int rowOf(int sq) => sq ~/ 4;

  static int colOf(int sq) => 2 * (sq % 4) + (rowOf(sq).isOdd ? 1 : 0);

  /// The square at [row], [col], or null for light squares or off the board.
  static int? squareAt(int row, int col) {
    if (row < 0 || row > 7 || col < 0 || col > 7) return null;
    final c = col - (row.isOdd ? 1 : 0);
    if (c.isOdd) return null;
    return row * 4 + c ~/ 2;
  }

  CheckersSquare? at(int sq) => _squares[sq];

  @override
  bool get drawOffers => true;

  @override
  Outcome? get outcome =>
      legalPaths().isEmpty ? Outcome(toMove.other, 'no_moves') : null;

  late final List<List<int>> _legal = _computeLegal();

  /// Every full legal move for [toMove], ordered by start square, then by
  /// direction (row-1/col-1, row-1/col+1, row+1/col-1, row+1/col+1), with
  /// jump sequences explored depth first.
  List<List<int>> legalPaths() => _legal;

  int get _farRow => toMove == Side.first ? 7 : 0;

  List<(int, int)> _dirs(CheckersPiece p) {
    if (p == CheckersPiece.king) return _diagonals;
    final dr = toMove == Side.first ? 1 : -1;
    return [
      for (final d in _diagonals)
        if (d.$1 == dr) d,
    ];
  }

  List<List<int>> _computeLegal() {
    final jumps = <List<int>>[];
    for (var sq = 0; sq < 32; sq++) {
      final p = _squares[sq];
      if (p == null || p.side != toMove) continue;
      final cells = List<CheckersSquare?>.of(_squares);
      cells[sq] = null;
      _jumps(cells, sq, p.piece, [sq], jumps);
    }
    if (jumps.isNotEmpty) return List.unmodifiable(jumps);

    final steps = <List<int>>[];
    for (var sq = 0; sq < 32; sq++) {
      final p = _squares[sq];
      if (p == null || p.side != toMove) continue;
      for (final (dr, dc) in _dirs(p.piece)) {
        final to = squareAt(rowOf(sq) + dr, colOf(sq) + dc);
        if (to != null && _squares[to] == null) {
          steps.add(List.unmodifiable([sq, to]));
        }
      }
    }
    return List.unmodifiable(steps);
  }

  /// Extends [path] (ending at [from]) with every jump sequence. [cells] has
  /// the moving piece lifted and captured pieces removed.
  void _jumps(
    List<CheckersSquare?> cells,
    int from,
    CheckersPiece piece,
    List<int> path,
    List<List<int>> out,
  ) {
    var extended = false;
    final r = rowOf(from), c = colOf(from);
    for (final (dr, dc) in _dirs(piece)) {
      final over = squareAt(r + dr, c + dc);
      final to = squareAt(r + 2 * dr, c + 2 * dc);
      if (over == null || to == null) continue;
      final victim = cells[over];
      if (victim == null || victim.side == toMove || cells[to] != null) {
        continue;
      }
      extended = true;
      final next = [...path, to];
      if (piece == CheckersPiece.man && rowOf(to) == _farRow) {
        out.add(List.unmodifiable(next));
        continue;
      }
      cells[over] = null;
      _jumps(cells, to, piece, next, out);
      cells[over] = victim;
    }
    if (!extended && path.length > 1) out.add(List.unmodifiable(path));
  }

  @override
  Board? play(Map<String, Object?> move) {
    final raw = move['path'];
    if (raw is! List || raw.length < 2) return null;
    final path = <int>[];
    for (final x in raw) {
      final e = wireInt(x);
      if (e == null || e < 0 || e > 31) return null;
      path.add(e);
    }
    List<int>? match;
    for (final l in legalPaths()) {
      if (_samePath(l, path)) {
        match = l;
        break;
      }
    }
    if (match == null) return null;

    final next = List<CheckersSquare?>.of(_squares);
    var piece = next[match.first]!;
    next[match.first] = null;
    for (var i = 1; i < match.length; i++) {
      final a = match[i - 1], b = match[i];
      if ((rowOf(a) - rowOf(b)).abs() == 2) {
        final over = squareAt(
          (rowOf(a) + rowOf(b)) ~/ 2,
          (colOf(a) + colOf(b)) ~/ 2,
        )!;
        next[over] = null;
      }
    }
    final end = match.last;
    if (piece.piece == CheckersPiece.man && rowOf(end) == _farRow) {
      piece = CheckersSquare(piece.side, CheckersPiece.king);
    }
    next[end] = piece;
    return CheckersBoard._(next, toMove.other, match);
  }
}

bool _samePath(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
