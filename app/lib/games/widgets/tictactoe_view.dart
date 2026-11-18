import 'package:material_ui/material_ui.dart';

import '../rules.dart';
import '../tictactoe.dart';
import 'board_parts.dart';

/// Tic-tac-toe: X (first) in the primary colour, O (second) in a warm red,
/// drawn as thick rounded strokes. The winning line's cells are tinted.
class TicTacToeView extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final colors = BoardColors.of(context);
    final canPlay =
        interactive && board.outcome == null && board.toMove == mySide;
    final line = board.winningLine ?? const <int>[];
    return LayoutBuilder(
      builder: (context, box) {
        final gap = box.biggest.shortestSide * 0.018;
        return BoardGrid(
          size: 3,
          thumbnail: thumbnail,
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
              radius: thumbnail ? 2 : 6,
              tint: line.contains(i) && side != null
                  ? markColor(context, side).withValues(alpha: 0.18)
                  : null,
              piece: side == null
                  ? null
                  : CustomPaint(
                      painter: _MarkPainter(side, markColor(context, side)),
                    ),
              onTap: playable ? () => onPlay(move) : null,
              label: thumbnail
                  ? null
                  : 'row ${r + 1} column ${c + 1}, ${_name(side)}',
            );
          },
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

class _MarkPainter extends CustomPainter {
  _MarkPainter(this.side, this.color);

  final Side side;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = s * 0.12
      ..strokeCap = StrokeCap.round;
    final c = size.center(Offset.zero);
    if (side == Side.first) {
      final d = s * 0.24;
      canvas.drawLine(c + Offset(-d, -d), c + Offset(d, d), paint);
      canvas.drawLine(c + Offset(d, -d), c + Offset(-d, d), paint);
    } else {
      canvas.drawCircle(c, s * 0.25, paint);
    }
  }

  @override
  bool shouldRepaint(_MarkPainter old) =>
      old.side != side || old.color != color;
}
