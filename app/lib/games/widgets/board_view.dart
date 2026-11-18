import 'package:material_ui/material_ui.dart';

import '../checkers.dart';
import '../chess_board.dart';
import '../dots_and_boxes.dart';
import '../four_in_a_row.dart';
import '../reversi.dart';
import '../rules.dart';
import '../tictactoe.dart';
import 'checkers_view.dart';
import 'chess_view.dart';
import 'dots_and_boxes_view.dart';
import 'four_in_a_row_view.dart';
import 'reversi_view.dart';
import 'tictactoe_view.dart';

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
      ),
      ReversiBoard() => ReversiView(
        board: b,
        mySide: widget.mySide,
        onPlay: widget.onPlay,
        interactive: interactive,
        thumbnail: widget.thumbnail,
      ),
      DotsAndBoxesBoard() => DotsAndBoxesView(
        board: b,
        mySide: widget.mySide,
        onPlay: widget.onPlay,
        interactive: interactive,
        thumbnail: widget.thumbnail,
        initials: widget.initials,
      ),
      _ => const SizedBox.shrink(),
    };
    if (!widget.thumbnail) return view;
    return IgnorePointer(child: ExcludeSemantics(child: view));
  }
}
