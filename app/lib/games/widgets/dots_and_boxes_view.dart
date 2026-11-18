import 'package:material_ui/material_ui.dart';

import '../dots_and_boxes.dart';
import '../rules.dart';
import 'board_parts.dart';

/// Dots and Boxes: 5x5 dots on a flat board. Drawn lines take the drawer's
/// colour (red-ish for the first player, blue-ish for the second), claimed
/// boxes are filled with the owner's colour and initial, and the last line is
/// highlighted. Each undrawn line has an invisible diamond-shaped tap target,
/// so a tap anywhere in a box picks its nearest side. Each player's name and
/// score sit above the board (not in thumbnails).
class DotsAndBoxesView extends StatelessWidget {
  const DotsAndBoxesView({
    super.key,
    required this.board,
    required this.mySide,
    required this.onPlay,
    required this.interactive,
    required this.thumbnail,
    this.initials,
    this.names,
  });

  final DotsAndBoxesBoard board;
  final Side? mySide;
  final void Function(Map<String, Object?> move) onPlay;
  final bool interactive, thumbnail;

  /// (first player's, second player's) initial, shown in claimed boxes.
  final (String, String)? initials;

  /// (first, second) players' display names for the scores, or null.
  final (String, String)? names;

  static Color sideColor(BuildContext context, Side side) {
    final dark = Theme.of(context).colorScheme.brightness == Brightness.dark;
    if (side == Side.first) {
      return dark ? const Color(0xFFFF6B7F) : const Color(0xFFD9363E);
    }
    return dark ? const Color(0xFF6FA8FF) : const Color(0xFF2F6FDE);
  }

  static String _colour(Side side) => side == Side.first ? 'red' : 'blue';

  static const _n = DotsAndBoxesBoard.size;
  static const _h = DotsAndBoxesBoard.horizontalCount;

  /// The two end dots of [line] as (row, col) in dot coordinates.
  static ((int, int), (int, int)) _ends(int line) {
    if (line < _h) {
      final r = line ~/ _n, c = line % _n;
      return ((r, c), (r, c + 1));
    }
    final v = line - _h;
    final r = v ~/ (_n + 1), c = v % (_n + 1);
    return ((r, c), (r + 1, c));
  }

  /// [line] as a box edge, e.g. "top edge of box 1" (boxes numbered from 1,
  /// row by row); an edge shared by two boxes is named from the lower or
  /// right one.
  static String lineName(int line) {
    if (line < _h) {
      final r = line ~/ _n, c = line % _n;
      return r < _n
          ? 'top edge of box ${r * _n + c + 1}'
          : 'bottom edge of box ${(r - 1) * _n + c + 1}';
    }
    final v = line - _h;
    final r = v ~/ (_n + 1), c = v % (_n + 1);
    return c < _n
        ? 'left edge of box ${r * _n + c + 1}'
        : 'right edge of box ${r * _n + c}';
  }

  String? _initial(Side side) {
    final i = initials;
    if (i == null || thumbnail) return null;
    final s = side == Side.first ? i.$1 : i.$2;
    return s.isEmpty ? null : s;
  }

  @override
  Widget build(BuildContext context) {
    final colors = BoardColors.of(context);
    final scheme = Theme.of(context).colorScheme;
    final canPlay =
        interactive && board.outcome == null && board.toMove == mySide;
    final first = sideColor(context, Side.first);
    final second = sideColor(context, Side.second);
    final grid = AspectRatio(
      aspectRatio: 1,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(thumbnail ? 6 : 14),
        child: ColoredBox(
          color: colors.light,
          child: LayoutBuilder(
            builder: (context, box) {
              final side = box.biggest.shortestSide;
              final margin = side * 0.08;
              final cell = (side - 2 * margin) / _n;
              Offset dot(int r, int c) =>
                  Offset(margin + c * cell, margin + r * cell);
              return Stack(
                children: [
                  for (var b = 0; b < DotsAndBoxesBoard.boxCount; b++)
                    if (board.owner(b) case final owner?)
                      Positioned(
                        left: dot(b ~/ _n, b % _n).dx,
                        top: dot(b ~/ _n, b % _n).dy,
                        width: cell,
                        height: cell,
                        child: _box(context, owner, cell, first, second),
                      ),
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _LinesPainter(
                        board: board,
                        dot: dot,
                        cell: cell,
                        first: first,
                        second: second,
                        neutral: scheme.onSurface.withValues(alpha: 0.7),
                        guide: colors.target.withValues(
                          alpha: colors.target.a * 0.5,
                        ),
                        highlight: colors.selected,
                        dots: scheme.onSurface,
                        thumbnail: thumbnail,
                      ),
                    ),
                  ),
                  for (var l = 0; l < DotsAndBoxesBoard.lineCount; l++)
                    _target(l, dot, cell, canPlay),
                ],
              );
            },
          ),
        ),
      ),
    );
    if (thumbnail) return grid;
    final (a, b) = board.scores;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ScoreRow(
          mySide: mySide,
          names: names,
          swatch: (side) => DecoratedBox(
            decoration: BoxDecoration(
              color: side == Side.first ? first : second,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
          score: (side) => side == Side.first ? a : b,
          describe: (side, name) {
            final n = side == Side.first ? a : b;
            final what = '$n ${n == 1 ? 'box' : 'boxes'}, ${_colour(side)}';
            return name == null ? what : '$name: $what';
          },
        ),
        Flexible(child: grid),
      ],
    );
  }

  Widget _box(
    BuildContext context,
    Side owner,
    double cell,
    Color first,
    Color second,
  ) {
    final color = owner == Side.first ? first : second;
    final initial = _initial(owner);
    return Padding(
      padding: EdgeInsets.all(cell * 0.06),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.28),
          borderRadius: BorderRadius.circular(thumbnail ? 1 : 4),
        ),
        child: initial == null
            ? null
            : Center(
                child: Text(
                  initial,
                  style: TextStyle(
                    color: color,
                    fontSize: cell * 0.42,
                    fontWeight: FontWeight.w800,
                    height: 1,
                  ),
                ),
              ),
      ),
    );
  }

  /// An invisible diamond around [line]'s midpoint: half of each adjacent box,
  /// so targets tile the board without overlapping.
  Widget _target(
    int line,
    Offset Function(int r, int c) dot,
    double cell,
    bool canPlay,
  ) {
    final ((r1, c1), (r2, c2)) = _ends(line);
    final mid = (dot(r1, c1) + dot(r2, c2)) / 2;
    final playable =
        canPlay && !board.drawn(line) && board.play({'line': line}) != null;
    return Positioned(
      left: mid.dx - cell / 2,
      top: mid.dy - cell / 2,
      width: cell,
      height: cell,
      child: Semantics(
        label:
            '${lineName(line)}, ${board.drawn(line) ? 'drawn' : 'not drawn'}',
        button: playable,
        excludeSemantics: true,
        child: ClipPath(
          clipper: const _Diamond(),
          child: GestureDetector(
            key: Key('line-$line'),
            behavior: HitTestBehavior.opaque,
            onTap: playable ? () => onPlay({'line': line}) : null,
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
  }
}

class _Diamond extends CustomClipper<Path> {
  const _Diamond();

  @override
  Path getClip(Size size) => Path()
    ..moveTo(size.width / 2, 0)
    ..lineTo(size.width, size.height / 2)
    ..lineTo(size.width / 2, size.height)
    ..lineTo(0, size.height / 2)
    ..close();

  @override
  bool shouldReclip(_Diamond oldClipper) => false;
}

class _LinesPainter extends CustomPainter {
  _LinesPainter({
    required this.board,
    required this.dot,
    required this.cell,
    required this.first,
    required this.second,
    required this.neutral,
    required this.guide,
    required this.highlight,
    required this.dots,
    required this.thumbnail,
  });

  final DotsAndBoxesBoard board;
  final Offset Function(int r, int c) dot;
  final double cell;
  final Color first, second, neutral, guide, highlight, dots;
  final bool thumbnail;

  @override
  void paint(Canvas canvas, Size size) {
    final width = cell * (thumbnail ? 0.08 : 0.07);
    Paint stroke(Color c, double w) => Paint()
      ..color = c
      ..strokeWidth = w
      ..strokeCap = StrokeCap.round;
    final last = board.lastLine;
    for (var l = 0; l < DotsAndBoxesBoard.lineCount; l++) {
      final ((r1, c1), (r2, c2)) = DotsAndBoxesView._ends(l);
      final a = dot(r1, c1), b = dot(r2, c2);
      if (!board.drawn(l)) {
        if (!thumbnail) canvas.drawLine(a, b, stroke(guide, width * 0.25));
        continue;
      }
      if (l == last) {
        canvas.drawLine(
          a,
          b,
          stroke(highlight.withValues(alpha: 0.45), width * 2.6),
        );
      }
      final color = switch (board.drawer(l)) {
        Side.first => first,
        Side.second => second,
        null => neutral,
      };
      canvas.drawLine(a, b, stroke(color, width));
    }
    final dotPaint = Paint()..color = dots;
    for (var r = 0; r <= DotsAndBoxesBoard.size; r++) {
      for (var c = 0; c <= DotsAndBoxesBoard.size; c++) {
        canvas.drawCircle(dot(r, c), width * 0.9, dotPaint);
      }
    }
  }

  @override
  bool shouldRepaint(_LinesPainter old) =>
      old.board != board ||
      old.cell != cell ||
      old.first != first ||
      old.second != second ||
      old.neutral != neutral ||
      old.guide != guide ||
      old.highlight != highlight ||
      old.dots != dots ||
      old.thumbnail != thumbnail;
}
