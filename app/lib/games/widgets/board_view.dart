import 'package:material_ui/material_ui.dart';

import '../checkers.dart';
import '../chess_board.dart';
import '../dots_and_boxes.dart';
import '../four_in_a_row.dart';
import '../go_fish.dart';
import '../landlord/landlord.dart';
import '../reversi.dart';
import '../rules.dart';
import '../tictactoe.dart';
import '../war.dart';
import 'checkers_view.dart';
import 'chess_view.dart';
import 'dots_and_boxes_view.dart';
import 'four_in_a_row_view.dart';
import 'go_fish_view.dart';
import 'landlord/landlord_view.dart';
import 'reversi_view.dart';
import 'tictactoe_view.dart';
import 'war_view.dart';

/// An interactive board for any game, with [mySide] at the bottom. With
/// [thumbnail] it is a static picture: no interaction, selection or labels.
///
/// Selection lives in the per-game views and clears when the position changes
/// (not merely the [board] instance).
class BoardView extends StatefulWidget {
  const BoardView({
    super.key,
    required this.board,
    required this.mySide,
    required this.onPlay,
    this.enabled = true,
    this.thumbnail = false,
    this.initials,
    this.names,
  });

  final Board board;

  /// Null for spectators: first at the bottom and no interaction.
  final Side? mySide;

  /// Only called with moves `board.play()` accepts.
  final void Function(Map<String, Object?> move) onPlay;
  final bool enabled, thumbnail;

  /// The (first, second) players' initials, shown where a game marks
  /// ownership (Dots and Boxes). Null shows colours only.
  final (String, String)? initials;

  /// The (first, second) players' display names ("You" for the viewer), shown
  /// by each player's colour and score (not in thumbnails). Null shows colours
  /// and scores only.
  final (String, String)? names;

  @override
  State<BoardView> createState() => _BoardViewState();
}

class _BoardViewState extends State<BoardView> {
  @override
  Widget build(BuildContext context) {
    final b = widget.board;
    final interactive =
        widget.enabled && !widget.thumbnail && widget.mySide != null;
    final Widget view = switch (b) {
      TicTacToeBoard() => TicTacToeView(
        board: b,
        mySide: widget.mySide,
        onPlay: widget.onPlay,
        interactive: interactive,
        thumbnail: widget.thumbnail,
      ),
      CheckersBoard() => CheckersView(
        board: b,
        mySide: widget.mySide,
        onPlay: widget.onPlay,
        interactive: interactive,
        thumbnail: widget.thumbnail,
      ),
      ChessBoard() => ChessView(
        board: b,
        mySide: widget.mySide,
        onPlay: widget.onPlay,
        interactive: interactive,
        thumbnail: widget.thumbnail,
      ),
      FourInARowBoard() => FourInARowView(
        board: b,
        mySide: widget.mySide,
        onPlay: widget.onPlay,
        interactive: interactive,
        thumbnail: widget.thumbnail,
        names: widget.names,
      ),
      ReversiBoard() => ReversiView(
        board: b,
        mySide: widget.mySide,
        onPlay: widget.onPlay,
        interactive: interactive,
        thumbnail: widget.thumbnail,
        names: widget.names,
      ),
      DotsAndBoxesBoard() => DotsAndBoxesView(
        board: b,
        mySide: widget.mySide,
        onPlay: widget.onPlay,
        interactive: interactive,
        thumbnail: widget.thumbnail,
        initials: widget.initials,
        names: widget.names,
      ),
      GoFishBoard() => GoFishView(
        board: b,
        mySide: widget.mySide,
        onPlay: widget.onPlay,
        interactive: interactive,
        thumbnail: widget.thumbnail,
        names: widget.names,
      ),
      WarBoard() => WarView(
        board: b,
        mySide: widget.mySide,
        onPlay: widget.onPlay,
        interactive: interactive,
        thumbnail: widget.thumbnail,
        names: widget.names,
      ),
      LandlordBoard() => LandlordView(
        board: b,
        mySide: widget.mySide,
        onPlay: widget.onPlay,
        interactive: interactive,
        thumbnail: widget.thumbnail,
        names: widget.names,
      ),
      _ => const SizedBox.shrink(),
    };
    if (!widget.thumbnail) return view;
    return IgnorePointer(child: ExcludeSemantics(child: view));
  }
}

/// The display aspect ratio (width / height) of [b]'s board: square, except
/// Four in a Row, Go Fish and Landlord (whose card pictures are counts and
/// balances only).
double boardAspectRatio(Board b) => switch (b) {
  FourInARowBoard() => FourInARowBoard.columns / FourInARowBoard.rows,
  GoFishBoard() || WarBoard() || LandlordBoard() => 3 / 2,
  _ => 1,
};

/// [side]'s colour on [b]'s board, as spoken ("white", "red", "X").
String sideColourName(Board b, Side side) {
  final first = side == Side.first;
  return switch (b) {
    TicTacToeBoard() => first ? 'X' : 'O',
    ChessBoard() => first ? 'white' : 'black',
    CheckersBoard() => first ? 'red' : 'black',
    FourInARowBoard() => first ? 'red' : 'yellow',
    ReversiBoard() => first ? 'dark' : 'light',
    _ => first ? 'red' : 'blue',
  };
}

/// The (first, second) score of a game played for points, or null.
(int, int)? boardScore(Board b) => switch (b) {
  ReversiBoard() => b.counts,
  DotsAndBoxesBoard() => b.scores,
  GoFishBoard() => b.scores,
  WarBoard() => b.won,
  _ => null,
};

/// A small sample of [side]'s pieces on [b]'s board, to sit by a name.
Widget sideSwatch(BuildContext context, Board b, Side side) => switch (b) {
  TicTacToeBoard() => FittedBox(
    child: Text(
      sideColourName(b, side),
      style: TextStyle(
        fontWeight: FontWeight.w800,
        color: TicTacToeView.markColor(context, side),
      ),
    ),
  ),
  ChessBoard() => ChessGlyph(piece: ChessPieceAt(side, ChessRole.pawn)),
  CheckersBoard() => CheckersDisc(
    piece: CheckersSquare(side, CheckersPiece.man),
  ),
  FourInARowBoard() => DecoratedBox(
    decoration: BoxDecoration(
      color: FourInARowView.discColor(context, side),
      shape: BoxShape.circle,
    ),
  ),
  ReversiBoard() => ReversiView.disc(side),
  _ => DecoratedBox(
    decoration: BoxDecoration(
      color: DotsAndBoxesView.sideColor(context, side),
      borderRadius: BorderRadius.circular(4),
    ),
  ),
};
