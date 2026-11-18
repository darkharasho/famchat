import 'package:material_ui/material_ui.dart';

import '../reversi.dart';
import '../rules.dart';
import 'board_parts.dart';

/// Reversi: an 8x8 board in a mid tone of the theme, so both disc colours
/// stand out, with dark discs for the first player and light discs for the
/// second, each ringed in the other colour. On my turn the legal cells show a
/// dot; the last disc placed is tinted. Each player's name and disc count sit
/// above the board (not in thumbnails).
class ReversiView extends StatelessWidget {
  const ReversiView({
    super.key,
    required this.board,
    required this.mySide,
    required this.onPlay,
    required this.interactive,
    required this.thumbnail,
    this.names,
  });

  final ReversiBoard board;
  final Side? mySide;
  final void Function(Map<String, Object?> move) onPlay;
  final bool interactive, thumbnail;

  /// (first, second) players' display names for the scores, or null.
  final (String, String)? names;

  static const _darkDisc = Color(0xFF20242E), _lightDisc = Color(0xFFF6F6F2);

  static Color discColor(Side side) =>
      side == Side.first ? _darkDisc : _lightDisc;

  /// The cell and gap colours: a mid tone in light mode (the shared light
  /// square is nearly white, like the light discs); dark mode's light square
  /// is already mid-toned.
  static (Color, Color) surface(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final colors = BoardColors.of(context);
    if (s.brightness == Brightness.dark) return (colors.light, colors.dark);
    return (
      Color.lerp(const Color(0xFFFFFFFF), s.primary, 0.5)!,
      Color.lerp(const Color(0xFFFFFFFF), s.primary, 0.72)!,
    );
  }

  /// A disc, ringed in the opposite disc colour so it reads on any square.
  static Widget disc(Side side, {double ring = 1.5}) => DecoratedBox(
    decoration: BoxDecoration(
      color: discColor(side),
      shape: BoxShape.circle,
      border: Border.all(
        color: side == Side.first
            ? _lightDisc.withValues(alpha: 0.35)
            : _darkDisc.withValues(alpha: 0.75),
        width: ring,
      ),
    ),
  );

  /// The square's name as on a chess board: a1 (56) at the bottom left.
  static String cellName(int i) =>
      '${'abcdefgh'[i % ReversiBoard.size]}${ReversiBoard.size - i ~/ ReversiBoard.size}';

  static String _colour(Side side) => side == Side.first ? 'dark' : 'light';

  @override
  Widget build(BuildContext context) {
    final colors = BoardColors.of(context);
    final (cellColor, gapColor) = surface(context);
    final canPlay =
        interactive && board.outcome == null && board.toMove == mySide;
    final legal = canPlay ? board.legalCells().toSet() : const <int>{};
    final grid = LayoutBuilder(
      builder: (context, box) {
        final gap = box.biggest.shortestSide * 0.012;
        return BoardGrid(
          size: ReversiBoard.size,
          thumbnail: thumbnail,
          background: gapColor,
          gap: gap,
          cell: (r, c) {
            final i = r * ReversiBoard.size + c;
            final side = board.at(i);
            final move = {'cell': i};
            final playable = legal.contains(i) && board.play(move) != null;
            return BoardSquare(
              key: Key('sq-$i'),
              color: cellColor,
              radius: thumbnail ? 1 : 4,
              tint: board.lastCell == i ? colors.lastMove : null,
              target: playable ? TargetMark.dot : TargetMark.none,
              targetColor: colors.target,
              label: thumbnail
                  ? null
                  : '${cellName(i)}, '
                        '${side == null ? 'empty' : '${_colour(side)} disc'}',
              onTap: playable ? () => onPlay(move) : null,
              piece: side == null
                  ? null
                  : Padding(
                      padding: EdgeInsets.all(thumbnail ? 1 : 3),
                      child: disc(side, ring: thumbnail ? 0.75 : 1.5),
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
        ScoreRow(
          mySide: mySide,
          names: names,
          swatch: disc,
          score: (side) => side == Side.first ? first : second,
          describe: (side, name) {
            final n = side == Side.first ? first : second;
            final what = '$n ${_colour(side)} ${n == 1 ? 'disc' : 'discs'}';
            return name == null ? what : '$name: $what';
          },
        ),
        Flexible(child: grid),
      ],
    );
  }
}
