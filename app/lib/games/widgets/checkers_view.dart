import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../checkers.dart';
import '../rules.dart';
import 'board_parts.dart';

/// Checkers. The viewer's back rank is at the bottom: row 0 for first (and
/// spectators), rotated 180° for second. A move is built tap by tap: the
/// piece, then each landing square; it is sent once it is a full legal path.
/// A move plays out hop by hop: the piece lifts and lands on each square, a
/// jumped piece shrinks away as it is passed, and a crown pops on at the end.
class CheckersView extends StatefulWidget {
  const CheckersView({
    super.key,
    required this.board,
    required this.mySide,
    required this.onPlay,
    required this.interactive,
    required this.thumbnail,
  });

  final CheckersBoard board;
  final Side? mySide;
  final void Function(Map<String, Object?> move) onPlay;
  final bool interactive, thumbnail;

  @override
  State<CheckersView> createState() => _CheckersViewState();
}

class _CheckersViewState extends MoveMotionState<CheckersView> {
  /// The piece and the landings chosen so far; empty when nothing is selected.
  List<int> _prefix = const [];

  /// The move playing out: its path, the piece before and after (a man may
  /// be crowned), and each jumped square with the hop that passes it.
  List<int> _path = const [];
  CheckersSquare? _mover, _landed;
  Map<int, (int, CheckersSquare)> _jumped = const {};

  static const _hopMs = 300, _crownMs = 260;

  @override
  void didUpdateWidget(CheckersView old) {
    super.didUpdateWidget(old);
    if (!_samePosition(old.board, widget.board) ||
        old.mySide != widget.mySide ||
        old.interactive != widget.interactive) {
      _prefix = const [];
    }
    if (!_samePosition(old.board, widget.board)) _plan(old.board);
  }

  static (int, int) _rc(int sq) =>
      (CheckersBoard.rowOf(sq), CheckersBoard.colOf(sq));

  void _plan(CheckersBoard a) {
    final b = widget.board, path = b.lastPath;
    if (widget.thumbnail || path == null || path.length < 2) return;
    final mover = a.at(path.first), landed = b.at(path.last);
    if (mover == null ||
        landed == null ||
        mover.side != landed.side ||
        b.at(path.first) != null && path.first != path.last) {
      return;
    }
    final jumped = <int, (int, CheckersSquare)>{};
    for (var sq = 0; sq < 32; sq++) {
      final was = a.at(sq), now = b.at(sq);
      if (sq == path.first || sq == path.last) continue;
      if (was == null && now == null) continue;
      if (was != null &&
          now != null &&
          was.side == now.side &&
          was.piece == now.piece) {
        continue;
      }
      // Only the mover's opponents may vanish; anything else is not one move.
      if (was == null || now != null || was.side == mover.side) return;
      final (r, c) = _rc(sq);
      var hop = -1;
      for (var h = 0; h + 1 < path.length; h++) {
        final (r1, c1) = _rc(path[h]);
        final (r2, c2) = _rc(path[h + 1]);
        if (r1 + r2 == 2 * r && c1 + c2 == 2 * c) hop = h;
      }
      if (hop < 0) return;
      jumped[sq] = (hop, was);
    }
    _path = path;
    _mover = mover;
    _landed = landed;
    _jumped = jumped;
    final crowned = mover.piece != landed.piece;
    playMove((path.length - 1) * _hopMs + (crowned ? _crownMs : 0));
  }

  int get _hopsMs => (_path.length - 1) * _hopMs;
  double get _hopsEnd => _hopsMs / (clock.duration?.inMilliseconds ?? _hopsMs);

  /// Games are re-derived (new Board objects) on every chat update, so the
  /// selection clears only when the position actually changed.
  static bool _samePosition(CheckersBoard a, CheckersBoard b) {
    if (identical(a, b)) return true;
    final pa = a.lastPath, pb = b.lastPath;
    return a.toMove == b.toMove &&
        (pa == null) == (pb == null) &&
        (pa == null || _startsWith(pa, pb!) && pa.length == pb.length) &&
        sameOutcome(a.outcome, b.outcome);
  }

  bool get _canPlay =>
      widget.interactive &&
      widget.board.outcome == null &&
      widget.board.toMove == widget.mySide;

  static bool _startsWith(List<int> path, List<int> prefix) {
    if (path.length < prefix.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (path[i] != prefix[i]) return false;
    }
    return true;
  }

  Set<int> get _targets {
    if (_prefix.isEmpty) return const {};
    return {
      for (final p in widget.board.legalPaths())
        if (p.length > _prefix.length && _startsWith(p, _prefix))
          p[_prefix.length],
    };
  }

  bool _isStart(int sq) => widget.board.legalPaths().any((p) => p[0] == sq);

  void _tap(int sq) {
    if (_prefix.isNotEmpty && _targets.contains(sq)) {
      final next = [..._prefix, sq];
      final complete = widget.board.legalPaths().any(
        (p) => p.length == next.length && _startsWith(p, next),
      );
      if (complete) {
        final move = {'path': next};
        setState(() => _prefix = const []);
        if (widget.board.play(move) != null) widget.onPlay(move);
      } else {
        setState(() => _prefix = next);
      }
      return;
    }
    setState(() {
      _prefix = _isStart(sq) && !(_prefix.length == 1 && _prefix[0] == sq)
          ? [sq]
          : const [];
    });
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: clock,
    builder: (context, _) => _build(context),
  );

  /// Where the moving piece is, in display cells from the top left (column,
  /// row), and how high it is lifted (0 on a square, 1 mid-hop).
  (Offset, double) _flight(bool flipped) {
    final hops = _path.length - 1;
    final t = (clock.value / _hopsEnd).clamp(0.0, 1.0) * hops;
    final h = math.min(t.floor(), hops - 1);
    final f = Curves.easeInOut.transform(t - h);
    Offset at(int sq) {
      final (r, c) = _rc(sq);
      return Offset(
        (flipped ? 7 - c : c).toDouble(),
        (flipped ? r : 7 - r).toDouble(),
      );
    }

    return (
      Offset.lerp(at(_path[h]), at(_path[h + 1]), f)!,
      math.sin(math.pi * f),
    );
  }

  Widget _build(BuildContext context) {
    final colors = BoardColors.of(context);
    final flipped = widget.mySide == Side.second;
    final animating = moving && _mover != null;
    final canPlay = _canPlay && !animating;
    final targets = _targets;
    final last = widget.board.lastPath ?? const <int>[];
    final selection = widget.thumbnail ? const <int>[] : _prefix;
    final hops = _path.length - 1;
    final grid = BoardGrid(
      size: 8,
      thumbnail: widget.thumbnail,
      cell: (r, c) {
        final row = flipped ? r : 7 - r;
        final col = flipped ? 7 - c : c;
        final sq = CheckersBoard.squareAt(row, col);
        if (sq == null) return ColoredBox(color: colors.light);
        var piece = widget.board.at(sq);
        Widget? drawn = piece == null
            ? null
            : AnimatedScale(
                scale: selection.isNotEmpty && sq == selection.first ? 1.1 : 1,
                duration: const Duration(milliseconds: 140),
                child: CheckersDisc(piece: piece),
              );
        if (animating) {
          if (sq == _path.last) drawn = null;
          final jump = _jumped[sq];
          if (jump != null) {
            // Shrinks away as the mover passes overhead (the hop's middle).
            final start = (jump.$1 + 0.35) / hops * _hopsEnd;
            final end = (jump.$1 + 0.75) / hops * _hopsEnd;
            final t = phase(start, end, Curves.easeIn);
            piece = jump.$2;
            drawn = t >= 1
                ? null
                : Opacity(
                    opacity: 1 - t,
                    child: Transform.scale(
                      scale: 1 - 0.6 * t,
                      child: CheckersDisc(piece: jump.$2),
                    ),
                  );
          }
        }
        final tappable =
            canPlay &&
            (_isStart(sq) || targets.contains(sq) || _prefix.isNotEmpty);
        return BoardSquare(
          key: Key('sq-$sq'),
          color: colors.dark,
          tint: selection.contains(sq) && sq != selection.last
              ? colors.selected.withValues(alpha: 0.25)
              : last.contains(sq)
              ? colors.lastMove
              : null,
          outline: selection.isNotEmpty && sq == selection.last
              ? colors.selected
              : null,
          piece: drawn,
          target: targets.contains(sq) ? TargetMark.dot : TargetMark.none,
          targetColor: colors.target,
          onTap: tappable ? () => _tap(sq) : null,
          label: widget.thumbnail ? null : _label(sq, widget.board.at(sq)),
        );
      },
    );
    if (!animating) return grid;
    final (at, lift) = _flight(flipped);
    final crowned = _mover!.piece != _landed!.piece;
    final crown = crowned ? phase(_hopsEnd, 1, Curves.easeOutBack) : 0.0;
    return Stack(
      children: [
        grid,
        Positioned.fill(
          child: IgnorePointer(
            child: LayoutBuilder(
              builder: (context, box) {
                final cell = box.biggest.shortestSide / 8;
                return Stack(
                  children: [
                    Positioned(
                      left: at.dx * cell,
                      top: at.dy * cell - lift * cell * 0.18,
                      width: cell,
                      height: cell,
                      child: Transform.scale(
                        scale: 1 + 0.18 * lift,
                        child: crown > 0
                            ? Stack(
                                fit: StackFit.expand,
                                children: [
                                  CheckersDisc(piece: _mover!),
                                  Opacity(
                                    opacity: crown.clamp(0.0, 1.0),
                                    child: Transform.scale(
                                      scale: 1.6 - 0.6 * crown,
                                      child: CheckersDisc(piece: _landed!),
                                    ),
                                  ),
                                ],
                              )
                            : CheckersDisc(piece: _mover!),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  static String _label(int sq, CheckersSquare? p) {
    if (p == null) return 'square $sq';
    final side = p.side == Side.first ? 'red' : 'black';
    final kind = p.piece == CheckersPiece.king ? 'king' : 'man';
    return 'square $sq, $side $kind';
  }
}

/// A checkers disc with soft radial shading; kings carry a painted crown.
/// Piece colours are fixed (red for first, near-black for second).
class CheckersDisc extends StatelessWidget {
  const CheckersDisc({super.key, required this.piece});

  final CheckersSquare piece;

  @override
  Widget build(BuildContext context) {
    final red = piece.side == Side.first;
    final base = red ? const Color(0xFFC62F2A) : const Color(0xFF2B2A30);
    final hi = red ? const Color(0xFFEF6A5C) : const Color(0xFF5A5862);
    final lo = red ? const Color(0xFF8E1C1A) : const Color(0xFF141317);
    return FractionallySizedBox(
      widthFactor: 0.8,
      heightFactor: 0.8,
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            center: const Alignment(-0.35, -0.4),
            radius: 0.95,
            colors: [hi, base, lo],
            stops: const [0, 0.55, 1],
          ),
          boxShadow: const [
            BoxShadow(
              color: Color(0x40000000),
              blurRadius: 2,
              offset: Offset(0, 1),
            ),
          ],
        ),
        child: piece.piece == CheckersPiece.king
            ? CustomPaint(painter: _CrownPainter())
            : null,
      ),
    );
  }
}

class _CrownPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final path = Path()
      ..moveTo(w * 0.27, h * 0.66)
      ..lineTo(w * 0.24, h * 0.36)
      ..lineTo(w * 0.38, h * 0.5)
      ..lineTo(w * 0.5, h * 0.3)
      ..lineTo(w * 0.62, h * 0.5)
      ..lineTo(w * 0.76, h * 0.36)
      ..lineTo(w * 0.73, h * 0.66)
      ..close();
    canvas.drawPath(path, Paint()..color = const Color(0xFFFFD25E));
    canvas.drawPath(
      path,
      Paint()
        ..color = const Color(0x66000000)
        ..style = PaintingStyle.stroke
        ..strokeWidth = w * 0.025
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_CrownPainter old) => false;
}
