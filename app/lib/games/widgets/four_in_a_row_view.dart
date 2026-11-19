import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../four_in_a_row.dart';
import '../rules.dart';
import 'board_parts.dart';

/// Four in a Row: an upright frame of 7 columns by 6 rows with round holes,
/// in a deep shade of the theme colour, holding shaded discs: red for the
/// first player and yellow for the second. A new disc drops down its column
/// behind the frame and settles with a small bounce; the winning four are
/// ringed and pulse once. The last disc carries a small light dot. Tap anywhere
/// in a column to drop a disc. Above the board (not in thumbnails) each
/// player's name sits by their colour.
class FourInARowView extends StatefulWidget {
  const FourInARowView({
    super.key,
    required this.board,
    required this.mySide,
    required this.onPlay,
    required this.interactive,
    required this.thumbnail,
    this.names,
  });

  final FourInARowBoard board;
  final Side? mySide;
  final void Function(Map<String, Object?> move) onPlay;
  final bool interactive, thumbnail;

  /// (first, second) players' display names, or null for no legend.
  final (String, String)? names;

  static Color discColor(BuildContext context, Side side) {
    final dark = Theme.of(context).colorScheme.brightness == Brightness.dark;
    if (side == Side.first) {
      return dark ? const Color(0xFFFF6B7F) : const Color(0xFFD9363E);
    }
    return dark ? const Color(0xFFFFD84D) : const Color(0xFFF2B600);
  }

  /// The frame's colour: the theme's primary, deepened so both discs pop.
  static Color frameColor(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return Color.lerp(
      s.primary,
      const Color(0xFF000000),
      s.brightness == Brightness.dark ? 0.45 : 0.18,
    )!;
  }

  static String _colour(Side side) => side == Side.first ? 'red' : 'yellow';

  @override
  State<FourInARowView> createState() => _FourInARowViewState();
}

class _FourInARowViewState extends MoveMotionState<FourInARowView> {
  static const cols = FourInARowBoard.columns, rows = FourInARowBoard.rows;

  /// The disc dropping in (column, row), and where the drop ends and the win
  /// pulse begins, as a fraction of the move.
  (int, int)? _drop;
  double _dropEnd = 1;
  bool _pulse = false;

  static int _count(FourInARowBoard b) {
    var n = 0;
    for (var c = 0; c < cols; c++) {
      for (var r = 0; r < rows; r++) {
        if (b.at(c, r) != null) n++;
      }
    }
    return n;
  }

  static int? _topRow(FourInARowBoard b, int c) {
    for (var r = rows - 1; r >= 0; r--) {
      if (b.at(c, r) != null) return r;
    }
    return null;
  }

  @override
  void didUpdateWidget(FourInARowView old) {
    super.didUpdateWidget(old);
    final b = widget.board, c = b.lastCol;
    if (widget.thumbnail || c == null || _count(b) != _count(old.board) + 1) {
      return;
    }
    final r = _topRow(b, c);
    if (r == null || old.board.at(c, r) != null) return;
    _drop = (c, r);
    // Falls further from higher up: a little longer for each row it passes.
    final fall = 260 + 45 * (rows - 1 - r);
    _pulse = b.winningLine != null && old.board.winningLine == null;
    final total = fall + 160 + (_pulse ? 600 : 0);
    _dropEnd = (fall + 160) / total;
    playMove(total);
  }

  @override
  Widget build(BuildContext context) {
    final frame = AspectRatio(
      aspectRatio: cols / rows,
      child: AnimatedBuilder(
        animation: clock,
        builder: (context, _) => LayoutBuilder(
          builder: (context, box) => _frame(context, box.biggest),
        ),
      ),
    );
    final n = widget.names;
    if (widget.thumbnail || n == null) return frame;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ScoreRow(
          mySide: widget.mySide,
          names: n,
          swatch: (side) => ShadedDisc(
            color: FourInARowView.discColor(context, side),
            rim: false,
          ),
          describe: (side, name) => name == null
              ? '${FourInARowView._colour(side)} discs'
              : '$name: ${FourInARowView._colour(side)} discs',
        ),
        Flexible(child: frame),
      ],
    );
  }

  /// The drop's height above its hole in cells at progress [t]: it falls
  /// under gravity, then bounces once a little and settles.
  double _lift(double t, int fromRows) {
    final land = 0.72;
    if (t < land) {
      final f = t / land;
      return fromRows * (1 - f * f);
    }
    final b = (t - land) / (1 - land);
    return 0.18 * math.sin(math.pi * b) * (fromRows > 0 ? 1 : 0.5);
  }

  Widget _frame(BuildContext context, Size size) {
    final board = widget.board;
    final colors = BoardColors.of(context);
    final thumbnail = widget.thumbnail;
    final canPlay =
        widget.interactive &&
        board.outcome == null &&
        board.toMove == widget.mySide;
    final line = board.winningLine ?? const <(int, int)>[];
    final lastCol = board.lastCol;
    final lastRow = lastCol == null ? null : _topRow(board, lastCol);
    final cell = size.width / cols;
    final radius = cell * 0.39;
    final animating = moving;
    final drop = animating ? _drop : null;
    final dropT = phase(0, _dropEnd);
    final pulse = animating && _pulse ? phase(_dropEnd, 1) : 0.0;
    Offset centerOf(int c, int r) =>
        Offset((c + 0.5) * cell, (rows - 1 - r + 0.5) * cell);
    final slot = Color.lerp(
      Theme.of(context).colorScheme.surface,
      FourInARowView.frameColor(context),
      0.18,
    )!;

    Widget disc(int c, int r) {
      final side = board.at(c, r);
      final key = Key('sq-${(rows - 1 - r) * cols + c}');
      if (side == null) return SizedBox(key: key);
      final win = line.contains((c, r));
      final grow = win ? 1 + 0.12 * math.sin(math.pi * pulse) : 1.0;
      return Transform.scale(
        scale: grow,
        child: ShadedDisc(
          key: key,
          color: FourInARowView.discColor(context, side),
          rim: !thumbnail,
          border: win
              ? Border.all(color: colors.selected, width: thumbnail ? 1.5 : 3)
              : null,
        ),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(thumbnail ? 6 : 14),
      child: Stack(
        children: [
          Positioned.fill(child: ColoredBox(color: slot)),
          // Discs sit behind the frame, so a falling disc shows only through
          // the holes it passes.
          for (var c = 0; c < cols; c++)
            for (var r = 0; r < rows; r++)
              _placed(
                c,
                r,
                centerOf(c, r),
                radius,
                cell,
                drop,
                dropT,
                disc(c, r),
              ),
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: _FramePainter(
                  color: FourInARowView.frameColor(context),
                  cell: cell,
                  hole: radius + cell * 0.015,
                  thumbnail: thumbnail,
                ),
              ),
            ),
          ),
          // The last disc's marker sits on top, once it has landed.
          if (!thumbnail &&
              lastCol != null &&
              lastRow != null &&
              (drop == null || dropT >= 0.72))
            Positioned(
              left: centerOf(lastCol, lastRow).dx - cell * 0.07,
              top: centerOf(lastCol, lastRow).dy - cell * 0.07,
              width: cell * 0.14,
              height: cell * 0.14,
              child: const IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Color(0xB3FFFFFF),
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ),
          Row(
            children: [
              for (var c = 0; c < cols; c++)
                Expanded(
                  child: _column(
                    c,
                    canPlay && !animating && board.play({'col': c}) != null,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// The disc at ([c], [r]) centred on [at], raised while it drops.
  Widget _placed(
    int c,
    int r,
    Offset at,
    double radius,
    double cell,
    (int, int)? drop,
    double dropT,
    Widget disc,
  ) {
    final dy = drop == (c, r) ? -_lift(dropT, rows - r) * cell : 0.0;
    return Positioned(
      left: at.dx - radius,
      top: at.dy - radius + dy,
      width: radius * 2,
      height: radius * 2,
      child: disc,
    );
  }

  Widget _column(int c, bool playable) {
    final move = {'col': c};
    var free = 0;
    while (free < rows && widget.board.at(c, rows - 1 - free) == null) {
      free++;
    }
    return Semantics(
      label: widget.thumbnail
          ? null
          : 'column ${c + 1}, ${free == 0 ? 'full' : '$free free'}',
      button: playable,
      container: true,
      child: GestureDetector(
        key: Key('col-$c'),
        behavior: HitTestBehavior.opaque,
        onTap: playable ? () => widget.onPlay(move) : null,
        child: const SizedBox.expand(),
      ),
    );
  }
}

/// The frame: a flat panel with a round hole per cell, each hole edged with a
/// soft shadow at its top so it reads as depth.
class _FramePainter extends CustomPainter {
  _FramePainter({
    required this.color,
    required this.cell,
    required this.hole,
    required this.thumbnail,
  });

  final Color color;
  final double cell, hole;
  final bool thumbnail;

  @override
  void paint(Canvas canvas, Size size) {
    // The panel with a hole per cell: even-odd fill leaves each oval empty.
    final panel = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size);
    for (var c = 0; c < FourInARowBoard.columns; c++) {
      for (var r = 0; r < FourInARowBoard.rows; r++) {
        panel.addOval(
          Rect.fromCircle(
            center: Offset((c + 0.5) * cell, (r + 0.5) * cell),
            radius: hole,
          ),
        );
      }
    }
    final (hi, lo) = discShades(color);
    canvas.drawPath(
      panel,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color.lerp(color, hi, 0.25)!,
            color,
            Color.lerp(color, lo, 0.3)!,
          ],
        ).createShader(Offset.zero & size),
    );
    if (thumbnail) return;
    // Each hole's rim: dark along the top inside edge, light along the bottom.
    final shade = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = cell * 0.035
      ..color = lo.withValues(alpha: 0.85);
    final light = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = cell * 0.025
      ..color = hi.withValues(alpha: 0.5);
    for (var c = 0; c < FourInARowBoard.columns; c++) {
      for (var r = 0; r < FourInARowBoard.rows; r++) {
        final rect = Rect.fromCircle(
          center: Offset((c + 0.5) * cell, (r + 0.5) * cell),
          radius: hole,
        );
        canvas.drawArc(rect, math.pi * 1.1, math.pi * 0.8, false, shade);
        canvas.drawArc(rect, math.pi * 0.15, math.pi * 0.7, false, light);
      }
    }
  }

  @override
  bool shouldRepaint(_FramePainter old) =>
      old.color != color ||
      old.cell != cell ||
      old.hole != hole ||
      old.thumbnail != thumbnail;
}
