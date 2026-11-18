import 'package:flutter/foundation.dart';

import 'rules.dart';

/// Dots and Boxes on 4x4 boxes (5x5 dots, 40 lines). Horizontal lines are
/// `0..19` = `row * 4 + col` (dot rows 0-4 top to bottom, cols 0-3); vertical
/// lines are `20..39` = `20 + row * 5 + col` (box rows 0-3, dot cols 0-4).
/// Boxes are `row * 4 + col`. Move: `{"line": 0..39}`; completing a box claims
/// it and the mover goes again. Most boxes wins once every line is drawn.
class DotsAndBoxesBoard implements Board {
  DotsAndBoxesBoard._(
    List<bool> lines,
    List<Side?> drawers,
    List<Side?> owners,
    this.lastLine,
    this._toMove,
  ) : _lines = List.unmodifiable(lines),
      _drawers = List.unmodifiable(drawers),
      _owners = List.unmodifiable(owners);

  factory DotsAndBoxesBoard.initial() => DotsAndBoxesBoard._(
    List.filled(lineCount, false),
    List.filled(lineCount, null),
    List.filled(boxCount, null),
    null,
    Side.first,
  );

  /// A position with [lines] drawn (drawer unknown), [owners] by box, and
  /// [toMove] due.
  @visibleForTesting
  factory DotsAndBoxesBoard.custom(
    Set<int> lines,
    Map<int, Side> owners,
    Side toMove,
  ) {
    final l = List.filled(lineCount, false);
    for (final i in lines) {
      l[i] = true;
    }
    final o = List<Side?>.filled(boxCount, null);
    owners.forEach((i, s) => o[i] = s);
    return DotsAndBoxesBoard._(
      l,
      List.filled(lineCount, null),
      o,
      null,
      toMove,
    );
  }

  /// Boxes per side.
  static const size = 4;
  static const boxCount = size * size;
  static const horizontalCount = (size + 1) * size;
  static const lineCount = 2 * horizontalCount;

  final List<bool> _lines;
  final List<Side?> _drawers, _owners;
  final Side _toMove;

  /// The last line drawn, or null on a fresh board.
  final int? lastLine;

  /// Whether [line] (0..39) is drawn.
  bool drawn(int line) => _lines[line];

  /// Who drew [line], or null if undrawn or unknown.
  Side? drawer(int line) => _drawers[line];

  /// The owner of [box] (`row * 4 + col`), or null if unclaimed.
  Side? owner(int box) => _owners[box];

  /// The lines around [box] as (top, bottom, left, right).
  static (int, int, int, int) boxLines(int box) {
    final r = box ~/ size, c = box % size;
    final left = horizontalCount + r * (size + 1) + c;
    return (r * size + c, (r + 1) * size + c, left, left + 1);
  }

  /// The boxes (one or two) that [line] borders.
  static List<int> boxesOf(int line) {
    if (line < horizontalCount) {
      final r = line ~/ size, c = line % size;
      return [if (r > 0) (r - 1) * size + c, if (r < size) r * size + c];
    }
    final v = line - horizontalCount;
    final r = v ~/ (size + 1), c = v % (size + 1);
    return [if (c > 0) r * size + c - 1, if (c < size) r * size + c];
  }

  /// Boxes claimed as (first, second).
  (int, int) get scores => (
    _owners.where((o) => o == Side.first).length,
    _owners.where((o) => o == Side.second).length,
  );

  bool get _over => !_lines.contains(false);

  @override
  Side get toMove => _toMove;

  @override
  Outcome? get outcome {
    if (!_over) return null;
    final (a, b) = scores;
    return Outcome(a == b ? null : (a > b ? Side.first : Side.second), 'boxes');
  }

  @override
  bool get drawOffers => false;

  @override
  Board? play(Map<String, Object?> move) {
    final line = move['line'];
    if (line is! int || line < 0 || line >= lineCount) return null;
    if (_lines[line] || _over) return null;
    final lines = List.of(_lines)..[line] = true;
    final drawers = List.of(_drawers)..[line] = _toMove;
    final owners = List.of(_owners);
    var claimed = false;
    for (final box in boxesOf(line)) {
      final (t, b, l, r) = boxLines(box);
      if (lines[t] && lines[b] && lines[l] && lines[r]) {
        owners[box] = _toMove;
        claimed = true;
      }
    }
    return DotsAndBoxesBoard._(
      lines,
      drawers,
      owners,
      line,
      claimed ? _toMove : _toMove.other,
    );
  }
}
