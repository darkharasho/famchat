import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../rules.dart';
import '../tictactoe.dart';
import 'board_parts.dart';

/// Tic-tac-toe: X (first) in the primary colour, O (second) in a warm red,
/// drawn as thick rounded strokes. A new mark draws itself in; a win is struck
/// through with a line in the winner's colour, and its cells are tinted.
class TicTacToeView extends StatefulWidget {
  const TicTacToeView({
    super.key,
    required this.board,
    required this.mySide,
    required this.onPlay,
    required this.interactive,
    required this.thumbnail,
  });

  final TicTacToeBoard board;
  final Side? mySide;
  final void Function(Map<String, Object?> move) onPlay;
  final bool interactive, thumbnail;

  static Color markColor(BuildContext context, Side side) {
    final s = Theme.of(context).colorScheme;
    if (side == Side.first) return s.primary;
    return s.brightness == Brightness.dark
        ? const Color(0xFFFF7088)
        : const Color(0xFFD9483B);
  }

  @override
  State<TicTacToeView> createState() => _TicTacToeViewState();
}

class _TicTacToeViewState extends MoveMotionState<TicTacToeView> {
  /// The cell whose mark is drawing in, and whether the strike-through plays.
  int? _fresh;
  bool _strike = false;

  @override
  void didUpdateWidget(TicTacToeView old) {
    super.didUpdateWidget(old);
    final a = old.board.cells, b = widget.board.cells;
    final changed = [
      for (var i = 0; i < 9; i++)
        if (a[i] != b[i]) i,
    ];
    if (widget.thumbnail || changed.length != 1 || a[changed.single] != null) {
      return;
    }
    _fresh = changed.single;
    _strike = widget.board.winningLine != null && old.board.winningLine == null;
    playMove(_strike ? 900 : 380);
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: clock,
    builder: (context, _) => _build(context),
  );

  Widget _build(BuildContext context) {
    final board = widget.board;
    final colors = BoardColors.of(context);
    final canPlay =
        widget.interactive &&
        board.outcome == null &&
        board.toMove == widget.mySide;
    final line = board.winningLine ?? const <int>[];
    final animating = moving;
    final draw = _strike
        ? phase(0, 0.42, Curves.easeOut)
        : phase(0, 1, Curves.easeOut);
    final strike = !animating || !_strike
        ? 1.0
        : phase(0.45, 1, Curves.easeInOut);
    return LayoutBuilder(
      builder: (context, box) {
        final gap = box.biggest.shortestSide * 0.018;
        final grid = BoardGrid(
          size: 3,
          thumbnail: widget.thumbnail,
          background: colors.dark,
          gap: gap,
          cell: (r, c) {
            final i = r * 3 + c;
            final side = board.cells[i];
            final move = {'cell': i};
            final playable = canPlay && board.play(move) != null;
            return BoardSquare(
              key: Key('sq-$i'),
              color: colors.light,
              radius: widget.thumbnail ? 2 : 6,
              tint: line.contains(i) && side != null
                  ? TicTacToeView.markColor(
                      context,
                      side,
                    ).withValues(alpha: 0.18 * strike)
                  : null,
              piece: side == null
                  ? null
                  : CustomPaint(
                      painter: _MarkPainter(
                        side,
                        TicTacToeView.markColor(context, side),
                        animating && i == _fresh ? draw : 1,
                      ),
                    ),
              onTap: playable ? () => widget.onPlay(move) : null,
              label: widget.thumbnail
                  ? null
                  : 'row ${r + 1} column ${c + 1}, ${_name(side)}',
            );
          },
        );
        final winner = line.isEmpty ? null : board.cells[line.first];
        if (winner == null || widget.thumbnail) return grid;
        return Stack(
          children: [
            grid,
            Positioned.fill(
              child: IgnorePointer(
                child: LayoutBuilder(
                  builder: (context, box) => CustomPaint(
                    painter: _StrikePainter(
                      line,
                      gap,
                      TicTacToeView.markColor(context, winner),
                      strike,
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

String _name(Side? side) => switch (side) {
  null => 'empty',
  Side.first => 'X',
  Side.second => 'O',
};

/// An X or O, drawn [progress] of the way (strokes in the order a hand would).
class _MarkPainter extends CustomPainter {
  _MarkPainter(this.side, this.color, this.progress);

  final Side side;
  final Color color;
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0) return;
    final s = size.shortestSide;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = s * 0.12
      ..strokeCap = StrokeCap.round;
    final c = size.center(Offset.zero);
    if (side == Side.first) {
      final d = s * 0.24;
      final one = (progress * 2).clamp(0.0, 1.0);
      final two = (progress * 2 - 1).clamp(0.0, 1.0);
      final a = c + Offset(-d, -d), b = c + Offset(d, d);
      canvas.drawLine(a, Offset.lerp(a, b, one)!, paint);
      if (two > 0) {
        final e = c + Offset(d, -d), f = c + Offset(-d, d);
        canvas.drawLine(e, Offset.lerp(e, f, two)!, paint);
      }
    } else {
      final r = s * 0.25;
      canvas.drawArc(
        Rect.fromCircle(center: c, radius: r),
        -math.pi / 2,
        2 * math.pi * progress,
        false,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_MarkPainter old) =>
      old.side != side || old.color != color || old.progress != progress;
}

/// The line through the three winning cells, drawn [progress] of the way.
class _StrikePainter extends CustomPainter {
  _StrikePainter(this.line, this.gap, this.color, this.progress);

  final List<int> line;
  final double gap, progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0) return;
    final cell = (size.shortestSide - 4 * gap) / 3;
    Offset center(int i) => Offset(
      gap + (i % 3) * (cell + gap) + cell / 2,
      gap + (i ~/ 3) * (cell + gap) + cell / 2,
    );
    final a = center(line.first), b = center(line.last);
    // Reach a little past the outer marks.
    final dir = (b - a) / (b - a).distance;
    final from = a - dir * cell * 0.38, to = b + dir * cell * 0.38;
    canvas.drawLine(
      from,
      Offset.lerp(from, to, progress)!,
      Paint()
        ..color = color.withValues(alpha: 0.9)
        ..strokeWidth = cell * 0.09
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_StrikePainter old) =>
      old.progress != progress || old.color != color || old.gap != gap;
}
