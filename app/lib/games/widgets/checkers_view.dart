import 'package:material_ui/material_ui.dart';

import '../checkers.dart';
import '../rules.dart';
import 'board_parts.dart';

/// Checkers. The viewer's back rank is at the bottom: row 0 for first (and
/// spectators), rotated 180° for second. A move is built tap by tap: the
/// piece, then each landing square; it is sent once it is a full legal path.
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

class _CheckersViewState extends State<CheckersView> {
  /// The piece and the landings chosen so far; empty when nothing is selected.
  List<int> _prefix = const [];

  @override
  void didUpdateWidget(CheckersView old) {
    super.didUpdateWidget(old);
    if (!identical(old.board, widget.board) ||
        old.mySide != widget.mySide ||
        old.interactive != widget.interactive) {
      _prefix = const [];
    }
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
  Widget build(BuildContext context) {
    final colors = BoardColors.of(context);
    final flipped = widget.mySide == Side.second;
    final canPlay = _canPlay;
    final targets = _targets;
    final last = widget.board.lastPath ?? const <int>[];
    final selection = widget.thumbnail ? const <int>[] : _prefix;
    return BoardGrid(
      size: 8,
      thumbnail: widget.thumbnail,
      cell: (r, c) {
        final row = flipped ? r : 7 - r;
        final col = flipped ? 7 - c : c;
        final sq = CheckersBoard.squareAt(row, col);
        if (sq == null) return ColoredBox(color: colors.light);
        final piece = widget.board.at(sq);
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
          piece: piece == null ? null : CheckersDisc(piece: piece),
          target: targets.contains(sq) ? TargetMark.dot : TargetMark.none,
          targetColor: colors.target,
          onTap: tappable ? () => _tap(sq) : null,
          label: widget.thumbnail ? null : _label(sq, piece),
        );
      },
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
