import 'package:material_ui/material_ui.dart';

import '../four_in_a_row.dart';
import '../rules.dart';
import 'board_parts.dart';

/// Four in a Row: a blue-tinted frame of 7 columns by 6 rows with drawn discs,
/// red for the first player and yellow for the second. Tap anywhere in a
/// column to drop a disc; the winning four are ringed and the last disc is
/// tinted.
class FourInARowView extends StatelessWidget {
  const FourInARowView({
    super.key,
    required this.board,
    required this.mySide,
    required this.onPlay,
    required this.interactive,
    required this.thumbnail,
  });

  final FourInARowBoard board;
  final Side? mySide;
  final void Function(Map<String, Object?> move) onPlay;
  final bool interactive, thumbnail;

  static Color discColor(BuildContext context, Side side) {
    final dark = Theme.of(context).colorScheme.brightness == Brightness.dark;
    if (side == Side.first) {
      return dark ? const Color(0xFFFF6B7F) : const Color(0xFFD9363E);
    }
    return dark ? const Color(0xFFFFD84D) : const Color(0xFFF2B600);
  }

  @override
  Widget build(BuildContext context) {
    final colors = BoardColors.of(context);
    final canPlay =
        interactive && board.outcome == null && board.toMove == mySide;
    final line = board.winningLine ?? const <(int, int)>[];
    final lastRow = _lastRow();
    final cols = FourInARowBoard.columns, rows = FourInARowBoard.rows;
    return AspectRatio(
      aspectRatio: cols / rows,
      child: LayoutBuilder(
        builder: (context, box) {
          final gap = box.biggest.shortestSide * 0.018;
          return ClipRRect(
            borderRadius: BorderRadius.circular(thumbnail ? 6 : 14),
            child: ColoredBox(
              color: colors.dark,
              child: Padding(
                padding: EdgeInsets.all(gap),
                child: Row(
                  children: [
                    for (var c = 0; c < cols; c++)
                      Expanded(
                        child: Padding(
                          padding: EdgeInsets.only(left: c == 0 ? 0 : gap),
                          child: _column(
                            context,
                            c,
                            gap,
                            colors,
                            line,
                            lastRow,
                            canPlay && board.play({'col': c}) != null,
                            rows,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  int? _lastRow() {
    final c = board.lastCol;
    if (c == null) return null;
    for (var r = FourInARowBoard.rows - 1; r >= 0; r--) {
      if (board.at(c, r) != null) return r;
    }
    return null;
  }

  Widget _column(
    BuildContext context,
    int c,
    double gap,
    BoardColors colors,
    List<(int, int)> line,
    int? lastRow,
    bool playable,
    int rows,
  ) {
    final move = {'col': c};
    return Semantics(
      label: thumbnail ? null : 'column ${c + 1}',
      button: playable,
      container: true,
      child: GestureDetector(
        key: Key('col-$c'),
        behavior: HitTestBehavior.opaque,
        onTap: playable ? () => onPlay(move) : null,
        child: Column(
          children: [
            for (var r = rows - 1; r >= 0; r--)
              Expanded(
                child: Padding(
                  padding: EdgeInsets.only(top: r == rows - 1 ? 0 : gap),
                  child: _cell(context, c, r, colors, line, lastRow),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _cell(
    BuildContext context,
    int c,
    int r,
    BoardColors colors,
    List<(int, int)> line,
    int? lastRow,
  ) {
    final side = board.at(c, r);
    final win = line.contains((c, r));
    final isLast = board.lastCol == c && lastRow == r;
    return BoardSquare(
      key: Key('sq-${(rows - 1 - r) * FourInARowBoard.columns + c}'),
      color: colors.light,
      radius: thumbnail ? 3 : 8,
      tint: isLast ? colors.lastMove : null,
      piece: side == null
          ? null
          : Padding(
              padding: const EdgeInsets.all(2),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: discColor(context, side),
                  shape: BoxShape.circle,
                  border: win
                      ? Border.all(
                          color: colors.selected,
                          width: thumbnail ? 1.5 : 3,
                        )
                      : null,
                ),
              ),
            ),
    );
  }

  static int get rows => FourInARowBoard.rows;
}
