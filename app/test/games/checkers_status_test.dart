import 'package:famchat/games/checkers.dart';
import 'package:famchat/games/game_state.dart';
import 'package:famchat/games/rules.dart';
import 'package:famchat/games/widgets/game_screen.dart';
import 'package:flutter_test/flutter_test.dart';

const _fm = CheckersSquare(Side.first, CheckersPiece.man);
const _sm = CheckersSquare(Side.second, CheckersPiece.man);

void main() {
  GameState game(CheckersBoard b) => GameState(
    id: 'g',
    type: GameType.checkers,
    firstUserId: 'me',
    secondUserId: 'mom',
    board: b,
    ply: 0,
    outcome: null,
    drawOfferedBy: null,
    inert: false,
    startedSeq: 1,
  );

  test('my turn with a capture due says I have to jump', () {
    const viewer = GameViewer(me: 'me', users: {}, readOnly: false);
    final due = CheckersBoard.custom({9: _fm, 13: _sm, 0: _fm}, Side.first);
    expect(viewer.status(game(due)), 'Your turn: you have to jump');
    final free = CheckersBoard.custom(
      {9: _fm, 13: _sm, 0: _fm},
      Side.first,
      optionalJumps: true,
    );
    expect(viewer.status(game(free)), 'Your turn');
    expect(viewer.status(game(CheckersBoard.initial())), 'Your turn');
  });
}
