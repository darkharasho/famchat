import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../reversi.dart';
import '../rules.dart';
import 'board_parts.dart';

/// Reversi: an 8x8 board in a mid tone of the theme, so both disc colours
/// stand out, with dark discs for the first player and light discs for the
/// second, each ringed in the other colour. On my turn the legal cells show a
/// dot; the last disc placed is tinted. Each player's name and disc count sit
/// above the board (not in thumbnails). A new disc pops in, then the discs it
/// turns flip over in a ripple outward from it.
class ReversiView extends StatefulWidget {
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
  static Widget disc(Side side, {double ring = 1.5}) {
    final base = discColor(side);
    final hi = side == Side.first
        ? const Color(0xFF4A5060)
        : const Color(0xFFFFFFFF);
    final lo = side == Side.first
        ? const Color(0xFF0E1015)
        : const Color(0xFFCFCFC8);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: base,
        shape: BoxShape.circle,
        gradient: RadialGradient(
          center: const Alignment(-0.35, -0.4),
          radius: 0.95,
          colors: [hi, base, lo],
          stops: const [0, 0.5, 1],
        ),
        boxShadow: ring > 1
            ? const [
                BoxShadow(
                  color: Color(0x40000000),
                  blurRadius: 2,
                  offset: Offset(0, 1),
                ),
              ]
            : null,
        border: Border.all(
          color: side == Side.first
              ? _lightDisc.withValues(alpha: 0.35)
              : _darkDisc.withValues(alpha: 0.75),
          width: ring,
        ),
      ),
    );
  }

  /// The square's name as on a chess board: a1 (56) at the bottom left.
  static String cellName(int i) =>
      '${'abcdefgh'[i % ReversiBoard.size]}${ReversiBoard.size - i ~/ ReversiBoard.size}';

  static String _colour(Side side) => side == Side.first ? 'dark' : 'light';

  @override
  State<ReversiView> createState() => _ReversiViewState();
}

class _ReversiViewState extends MoveMotionState<ReversiView> {
  static const _n = ReversiBoard.size;

  /// The disc just placed, and each turned disc's flip start and end as
  /// fractions of the move.
  int? _placed;
  Map<int, (double, double)> _flips = const {};

  static const _popMs = 240, _flipMs = 320, _stepMs = 90, _leadMs = 150;

  @override
  void didUpdateWidget(ReversiView old) {
    super.didUpdateWidget(old);
    final a = old.board, b = widget.board, at = b.lastCell;
    if (widget.thumbnail ||
        at == null ||
        a.at(at) != null ||
        b.at(at) == null) {
      return;
    }
    final flipped = <int>[];
    for (var i = 0; i < _n * _n; i++) {
      if (i == at || a.at(i) == b.at(i)) continue;
      // Anything but a disc turning over is not one move: show it as is.
      if (a.at(i) == null || b.at(i) == null) return;
      flipped.add(i);
    }
    int dist(int i) =>
        math.max((i ~/ _n - at ~/ _n).abs(), (i % _n - at % _n).abs());
    final far = flipped.fold(1, (m, i) => math.max(m, dist(i)));
    final total = math.max(_popMs, _leadMs + (far - 1) * _stepMs + _flipMs);
    _placed = at;
    _flips = {
      for (final i in flipped)
        i: (
          (_leadMs + (dist(i) - 1) * _stepMs) / total,
          (_leadMs + (dist(i) - 1) * _stepMs + _flipMs) / total,
        ),
    };
    _popEnd = _popMs / total;
    playMove(total);
  }

  double _popEnd = 1;

  /// [i]'s disc part-way through the move: the new disc grows in; a turned
  /// disc narrows to its edge, shows its new colour, and widens again,
  /// rising a little at the turn.
  Widget _piece(int i, Side side, bool thumbnail) {
    var disc = ReversiView.disc(side, ring: thumbnail ? 0.75 : 1.5);
    if (!moving) return disc;
    if (i == _placed) {
      final t = phase(0, _popEnd, Curves.easeOutBack);
      return Opacity(
        opacity: phase(0, _popEnd * 0.5).clamp(0.0, 1.0),
        child: Transform.scale(scale: 0.3 + 0.7 * t, child: disc),
      );
    }
    final f = _flips[i];
    if (f == null) return disc;
    final t = phase(f.$1, f.$2, Curves.easeInOut);
    if (t < 0.5) {
      disc = ReversiView.disc(side.other, ring: thumbnail ? 0.75 : 1.5);
    }
    return Transform(
      alignment: Alignment.center,
      transform: Matrix4.diagonal3Values(
        math.max(0.04, (math.cos(math.pi * t)).abs()) *
            (1 + 0.15 * math.sin(math.pi * t)),
        1 + 0.15 * math.sin(math.pi * t),
        1,
      ),
      child: disc,
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: clock,
    builder: (context, _) => _build(context),
  );

  Widget _build(BuildContext context) {
    final board = widget.board, thumbnail = widget.thumbnail;
    final mySide = widget.mySide, names = widget.names;
    final colors = BoardColors.of(context);
    final (cellColor, gapColor) = ReversiView.surface(context);
    final canPlay =
        widget.interactive &&
        board.outcome == null &&
        board.toMove == mySide &&
        !moving;
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
                  : '${ReversiView.cellName(i)}, '
                        '${side == null ? 'empty' : '${ReversiView._colour(side)} disc'}',
              onTap: playable ? () => widget.onPlay(move) : null,
              piece: side == null
                  ? null
                  : Padding(
                      padding: EdgeInsets.all(thumbnail ? 1 : 3),
                      child: _piece(i, side, thumbnail),
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
          swatch: ReversiView.disc,
          score: (side) => side == Side.first ? first : second,
          describe: (side, name) {
            final n = side == Side.first ? first : second;
            final what =
                '$n ${ReversiView._colour(side)} ${n == 1 ? 'disc' : 'discs'}';
            return name == null ? what : '$name: $what';
          },
        ),
        Flexible(child: grid),
      ],
    );
  }
}
