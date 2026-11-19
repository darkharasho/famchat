import 'package:material_ui/material_ui.dart';

import '../chess_board.dart';
import '../rules.dart';
import 'board_parts.dart';

const _files = 'abcdefgh';

/// Solid glyphs for both sides; U+FE0E asks for text, never emoji.
const _glyphs = {
  ChessRole.king: '♚︎',
  ChessRole.queen: '♛︎',
  ChessRole.rook: '♜︎',
  ChessRole.bishop: '♝︎',
  ChessRole.knight: '♞︎',
  ChessRole.pawn: '♟︎',
};

const _promotions = [
  ('q', ChessRole.queen),
  ('r', ChessRole.rook),
  ('b', ChessRole.bishop),
  ('n', ChessRole.knight),
];

/// Chess. White at the bottom for first (and spectators), flipped for second.
/// Tap a piece, then a target; a promotion asks which piece to take. A move
/// slides its piece (and a castling rook) across; a captured piece fades as
/// it is taken, and a promoted pawn turns into its new piece as it lands.
class ChessView extends StatefulWidget {
  const ChessView({
    super.key,
    required this.board,
    required this.mySide,
    required this.onPlay,
    required this.interactive,
    required this.thumbnail,
  });

  final ChessBoard board;
  final Side? mySide;
  final void Function(Map<String, Object?> move) onPlay;
  final bool interactive, thumbnail;

  @override
  State<ChessView> createState() => _ChessViewState();
}

class _ChessViewState extends MoveMotionState<ChessView> {
  String? _selected;

  /// The move playing out: each sliding piece's (from, to, piece before,
  /// piece after), and each captured square with the piece taken there.
  List<(String, String, ChessPieceAt, ChessPieceAt)> _slides = const [];
  Map<String, ChessPieceAt> _taken = const {};

  static bool _same(ChessPieceAt? a, ChessPieceAt? b) =>
      a?.side == b?.side && a?.role == b?.role;

  static String _sq(int file, int rank) => '${_files[file]}${rank + 1}';

  void _plan(ChessBoard a) {
    final b = widget.board, last = b.lastMove;
    if (widget.thumbnail || last == null || last == a.lastMove) return;
    final (from, to) = last;
    final mover = a.at(from), landed = b.at(to);
    if (mover == null ||
        landed == null ||
        mover.side != landed.side ||
        b.at(from) != null) {
      return;
    }
    final slides = [(from, to, mover, landed)];
    final taken = <String, ChessPieceAt>{};
    final gone = <String>[], came = <String>[];
    for (var f = 0; f < 8; f++) {
      for (var r = 0; r < 8; r++) {
        final sq = _sq(f, r);
        if (sq == from || sq == to) {
          final was = a.at(sq);
          if (sq == to && was != null) taken[sq] = was;
          continue;
        }
        final was = a.at(sq), now = b.at(sq);
        if (_same(was, now)) continue;
        if (was != null && was.side != mover.side && now == null) {
          taken[sq] = was; // en passant
        } else if (was != null && was.side == mover.side && now == null) {
          gone.add(sq);
        } else if (was == null && now?.side == mover.side) {
          came.add(sq);
        } else {
          return;
        }
      }
    }
    // Castling: the rook's one square left and one arrived.
    if (gone.length != came.length || gone.length > 1) return;
    if (gone.length == 1) {
      final rook = a.at(gone.single)!;
      slides.add((gone.single, came.single, rook, rook));
    }
    _slides = slides;
    _taken = taken;
    playMove(340);
  }

  /// [sq] in display cells from the top left (column, row).
  static Offset _cellOf(String sq, bool flipped) {
    final file = _files.indexOf(sq[0]), rank = int.parse(sq[1]) - 1;
    return Offset(
      (flipped ? 7 - file : file).toDouble(),
      (flipped ? rank : 7 - rank).toDouble(),
    );
  }

  /// The destination waiting on the promotion picker.
  String? _promoTo;

  @override
  void didUpdateWidget(ChessView old) {
    super.didUpdateWidget(old);
    if (!_samePosition(old.board, widget.board) ||
        old.mySide != widget.mySide ||
        old.interactive != widget.interactive) {
      _selected = null;
      _promoTo = null;
    }
    if (!_samePosition(old.board, widget.board)) _plan(old.board);
  }

  /// Games are re-derived (new Board objects) on every chat update, so the
  /// selection clears only when the position actually changed.
  static bool _samePosition(ChessBoard a, ChessBoard b) =>
      identical(a, b) ||
      a.toMove == b.toMove &&
          a.lastMove == b.lastMove &&
          sameOutcome(a.outcome, b.outcome);

  bool get _canPlay =>
      widget.interactive &&
      widget.board.outcome == null &&
      widget.board.toMove == widget.mySide;

  bool _selectable(String sq) =>
      widget.board.at(sq)?.side == widget.mySide &&
      widget.board.targetsFrom(sq).isNotEmpty;

  void _send(String uci) {
    final move = {'uci': uci};
    setState(() {
      _selected = null;
      _promoTo = null;
    });
    if (widget.board.play(move) != null) widget.onPlay(move);
  }

  void _tap(String sq) {
    final from = _selected;
    if (from != null && widget.board.targetsFrom(from).contains(sq)) {
      if (widget.board.needsPromotion(from, sq)) {
        setState(() => _promoTo = sq);
      } else {
        _send('$from$sq');
      }
      return;
    }
    setState(() => _selected = sq != from && _selectable(sq) ? sq : null);
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: clock,
    builder: (context, _) => _build(context),
  );

  Widget _build(BuildContext context) {
    final colors = BoardColors.of(context);
    final flipped = widget.mySide == Side.second;
    final animating = moving && _slides.isNotEmpty;
    final canPlay = _canPlay && !animating;
    final slide = phase(0, 1, Curves.easeInOutCubic);
    final fade = phase(0.55, 1, Curves.easeIn);
    final landing = {for (final s in _slides) s.$2};
    final board = widget.board;
    final selected = widget.thumbnail ? null : _selected;
    final targets = selected == null
        ? const <String>[]
        : board.targetsFrom(selected);
    final last = board.lastMove;
    final inCheck = board.inCheck;
    final grid = BoardGrid(
      size: 8,
      thumbnail: widget.thumbnail,
      cell: (r, c) {
        final file = flipped ? 7 - c : c;
        final rank = flipped ? r : 7 - r; // 0-based
        final sq = '${_files[file]}${rank + 1}';
        final dark = (file + rank).isEven;
        final piece = board.at(sq);
        final checked =
            inCheck &&
            piece?.role == ChessRole.king &&
            piece?.side == board.toMove;
        final tappable = canPlay && (selected != null || _selectable(sq));
        return BoardSquare(
          key: Key('sq-$sq'),
          color: dark ? colors.dark : colors.light,
          tint: checked
              ? colors.check
              : last != null && (last.$1 == sq || last.$2 == sq)
              ? colors.lastMove
              : null,
          outline: sq == selected ? colors.selected : null,
          overlay: widget.thumbnail
              ? null
              : _Coords(
                  fileLabel: r == 7 ? _files[file] : null,
                  rankLabel: c == 0 ? '${rank + 1}' : null,
                  color: dark ? colors.light : colors.dark,
                ),
          piece: animating && _taken.containsKey(sq)
              ? Opacity(
                  opacity: 1 - fade,
                  child: Transform.scale(
                    scale: 1 - 0.3 * fade,
                    child: ChessGlyph(piece: _taken[sq]!),
                  ),
                )
              : piece == null || animating && landing.contains(sq)
              ? null
              : AnimatedScale(
                  scale: sq == selected ? 1.12 : 1,
                  duration: const Duration(milliseconds: 140),
                  child: ChessGlyph(piece: piece),
                ),
          target: !targets.contains(sq)
              ? TargetMark.none
              : piece != null
              ? TargetMark.ring
              : TargetMark.dot,
          targetColor: colors.target,
          onTap: tappable ? () => _tap(sq) : null,
          label: widget.thumbnail ? null : _label(sq, piece),
        );
      },
    );
    final Widget shown = !animating
        ? grid
        : Stack(
            children: [
              grid,
              Positioned.fill(
                child: IgnorePointer(
                  child: LayoutBuilder(
                    builder: (context, box) {
                      final cell = box.biggest.shortestSide / 8;
                      return Stack(
                        children: [
                          for (final (a, b, before, after) in _slides)
                            Positioned(
                              left:
                                  Offset.lerp(
                                    _cellOf(a, flipped),
                                    _cellOf(b, flipped),
                                    slide,
                                  )!.dx *
                                  cell,
                              top:
                                  Offset.lerp(
                                    _cellOf(a, flipped),
                                    _cellOf(b, flipped),
                                    slide,
                                  )!.dy *
                                  cell,
                              width: cell,
                              height: cell,
                              child: Transform.scale(
                                // Lifts a touch mid-slide.
                                scale: 1 + 0.1 * (1 - (2 * slide - 1).abs()),
                                child: ChessGlyph(
                                  piece: slide < 0.8 ? before : after,
                                ),
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
    final from = _selected, to = _promoTo;
    if (from == null || to == null || widget.thumbnail) return shown;
    return Stack(
      children: [
        shown,
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _promoTo = null),
            child: ColoredBox(
              color: const Color(0x66000000),
              child: LayoutBuilder(
                builder: (context, box) => Center(
                  // Taps on the picker itself (between its buttons) are
                  // not a cancel.
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {},
                    child: _PromotionPicker(
                      key: const Key('promo-picker'),
                      side: board.toMove,
                      // Four buttons with their padding in 92% of the board.
                      square: ((box.maxWidth * 0.92 - 12) / 4 - 4).clamp(
                        16.0,
                        52.0,
                      ),
                      onPick: (p) => _send('$from$to$p'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  static String _label(String sq, ChessPieceAt? p) {
    if (p == null) return sq;
    final side = p.side == Side.first ? 'white' : 'black';
    return '$sq $side ${p.role.name}';
  }
}

/// A chess piece: a solid glyph filled white (first) or dark (second) over a
/// stroked copy that outlines it against any square.
class ChessGlyph extends StatelessWidget {
  const ChessGlyph({super.key, required this.piece});

  final ChessPieceAt piece;

  @override
  Widget build(BuildContext context) {
    final white = piece.side == Side.first;
    final glyph = _glyphs[piece.role]!;
    return LayoutBuilder(
      builder: (context, box) {
        final size = box.biggest.shortestSide * 0.8;
        TextStyle style(Paint? foreground, Color? color) => TextStyle(
          fontFamily: 'NotoSansSymbols2',
          fontSize: size,
          height: 1,
          color: color,
          foreground: foreground,
        );
        return Center(
          child: Stack(
            alignment: Alignment.center,
            children: [
              Text(
                glyph,
                textAlign: TextAlign.center,
                style: style(
                  Paint()
                    ..style = PaintingStyle.stroke
                    ..strokeWidth = size * (white ? 0.09 : 0.06)
                    ..strokeJoin = StrokeJoin.round
                    ..color = white
                        ? const Color(0xFF221E2A)
                        : const Color(0xCCFFFFFF),
                  null,
                ),
              ),
              Text(
                glyph,
                textAlign: TextAlign.center,
                style: style(
                  null,
                  white ? const Color(0xFFFFFFFF) : const Color(0xFF221E2A),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Coords extends StatelessWidget {
  const _Coords({this.fileLabel, this.rankLabel, required this.color});

  final String? fileLabel, rankLabel;
  final Color color;

  @override
  Widget build(BuildContext context) {
    if (fileLabel == null && rankLabel == null) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, box) {
        final style = TextStyle(
          fontSize: box.biggest.shortestSide * 0.2,
          fontWeight: FontWeight.w700,
          color: color,
          height: 1,
        );
        final pad = box.biggest.shortestSide * 0.06;
        return Stack(
          children: [
            if (rankLabel != null)
              Positioned(
                left: pad,
                top: pad,
                child: Text(rankLabel!, style: style),
              ),
            if (fileLabel != null)
              Positioned(
                right: pad,
                bottom: pad,
                child: Text(fileLabel!, style: style),
              ),
          ],
        );
      },
    );
  }
}

class _PromotionPicker extends StatelessWidget {
  const _PromotionPicker({
    super.key,
    required this.side,
    required this.square,
    required this.onPick,
  });

  final Side side;

  /// Each button's side.
  final double square;
  final void Function(String piece) onPick;

  @override
  Widget build(BuildContext context) {
    final colors = BoardColors.of(context);
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLowest,
      borderRadius: BorderRadius.circular(14),
      elevation: 6,
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (letter, role) in _promotions)
              Padding(
                padding: const EdgeInsets.all(2),
                child: Semantics(
                  label: 'Promote to ${role.name}',
                  button: true,
                  excludeSemantics: true,
                  child: InkWell(
                    key: Key('promo-$letter'),
                    borderRadius: BorderRadius.circular(10),
                    onTap: () => onPick(letter),
                    child: Ink(
                      width: square,
                      height: square,
                      decoration: BoxDecoration(
                        color: colors.light,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: ChessGlyph(piece: ChessPieceAt(side, role)),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
