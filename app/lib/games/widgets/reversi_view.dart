import 'package:material_ui/material_ui.dart';

import '../reversi.dart';
import '../rules.dart';
import 'board_parts.dart';

/// Reversi: a flat 8x8 board with dark discs for the first player and light
/// discs for the second. On my turn the legal cells show a dot; the last disc
/// placed is tinted. Both disc counts sit above the board (not in thumbnails).
class ReversiView extends StatelessWidget {
  const ReversiView({
    super.key,
    required this.board,
    required this.mySide,
    required this.onPlay,
    required this.interactive,
    required this.thumbnail,
  });

  final ReversiBoard board;
  final Side? mySide;
  final void Function(Map<String, Object?> move) onPlay;
  final bool interactive, thumbnail;

  static Color discColor(Side side) =>
      side == Side.first ? const Color(0xFF20242E) : const Color(0xFFF6F6F2);

  @override
  Widget build(BuildContext context) {
    final colors = BoardColors.of(context);
    final canPlay =
        interactive && board.outcome == null && board.toMove == mySide;
    final legal = canPlay ? board.legalCells().toSet() : const <int>{};
    final grid = LayoutBuilder(
      builder: (context, box) {
        final gap = box.biggest.shortestSide * 0.012;
        return BoardGrid(
          size: ReversiBoard.size,
          thumbnail: thumbnail,
          background: colors.dark,
          gap: gap,
          cell: (r, c) {
            final i = r * ReversiBoard.size + c;
            final side = board.at(i);
            final move = {'cell': i};
            final playable = legal.contains(i) && board.play(move) != null;
            return BoardSquare(
              key: Key('sq-$i'),
              color: colors.light,
              radius: thumbnail ? 1 : 4,
              tint: board.lastCell == i ? colors.lastMove : null,
              target: playable ? TargetMark.dot : TargetMark.none,
              targetColor: colors.target,
              label: thumbnail ? null : 'cell ${i + 1}',
              onTap: playable ? () => onPlay(move) : null,
              piece: side == null
                  ? null
                  : Padding(
                      padding: EdgeInsets.all(thumbnail ? 1 : 3),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: discColor(side),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: const Color(0x66808080),
                            width: thumbnail ? 0.5 : 1,
                          ),
                        ),
                      ),
                    ),
            );
          },
        );
      },
    );
    if (thumbnail) return grid;
    final (first, second) = board.counts;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _count(context, Side.first, first),
              _count(context, Side.second, second),
            ],
          ),
        ),
        Flexible(child: grid),
      ],
    );
  }

  Widget _count(BuildContext context, Side side, int n) => Semantics(
    label: '${side == Side.first ? 'dark' : 'light'} $n',
    excludeSemantics: true,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 16,
          height: 16,
          decoration: BoxDecoration(
            color: discColor(side),
            shape: BoxShape.circle,
            border: Border.all(color: const Color(0x66808080)),
          ),
        ),
        const SizedBox(width: 6),
        Text(
          '$n',
          key: Key('count-${side.name}'),
          style: Theme.of(context).textTheme.titleMedium
              ?.copyWith(fontWeight: FontWeight.w700),
        ),
      ],
    ),
  );
}
