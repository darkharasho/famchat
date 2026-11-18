import 'package:famchat/games/four_in_a_row.dart';
import 'package:famchat/games/rules.dart';
import 'package:flutter_test/flutter_test.dart';

FourInARowBoard start() => FourInARowBoard.initial();

FourInARowBoard _drop(FourInARowBoard b, List<int> cols) {
  var cur = b;
  for (final c in cols) {
    cur = cur.play({'col': c})! as FourInARowBoard;
  }
  return cur;
}

void main() {
  test('first player moves first', () {
    expect(start().toMove, Side.first);
    expect(start().outcome, isNull);
    expect(start().drawOffers, isFalse);
    expect(_drop(start(), [3]).toMove, Side.second);
  });

  test('disc falls to the lowest empty cell', () {
    final b = _drop(start(), [3, 3, 3]);
    expect(b.at(3, 0), Side.first);
    expect(b.at(3, 1), Side.second);
    expect(b.at(3, 2), Side.first);
    expect(b.at(3, 3), isNull);
    expect(b.lastCol, 3);
  });

  test('play never mutates the original', () {
    final b = start();
    b.play({'col': 0});
    expect(b.at(0, 0), isNull);
  });

  test('full column is illegal', () {
    final b = _drop(start(), [0, 0, 0, 0, 0, 0]);
    expect(b.play({'col': 0}), isNull);
    expect(b.play({'col': 1}), isNotNull);
  });

  test("bad col (7, -1, '3', 3.5, missing) returns null", () {
    expect(start().play({'col': 7}), isNull);
    expect(start().play({'col': -1}), isNull);
    expect(start().play({'col': '3'}), isNull);
    expect(start().play({'col': 3.5}), isNull);
    expect(start().play({}), isNull);
  });

  test('an integral double col plays like the int', () {
    final b = start().play({'col': 3.0})! as FourInARowBoard;
    expect(b.at(3, 0), Side.first);
    expect(b.lastCol, 3);
  });

  test('horizontal, vertical and both diagonal fours win with reason line', () {
    // Horizontal: first plays 0..3 on the bottom, second stacks on 0..2.
    var b = _drop(start(), [0, 0, 1, 1, 2, 2, 3]);
    expect(b.outcome!.winner, Side.first);
    expect(b.outcome!.reason, 'line');
    expect(b.winningLine, [(0, 0), (1, 0), (2, 0), (3, 0)]);

    // Vertical: first stacks column 0, second column 1.
    b = _drop(start(), [0, 1, 0, 1, 0, 1, 0]);
    expect(b.outcome!.winner, Side.first);
    expect(b.winningLine, [(0, 0), (0, 1), (0, 2), (0, 3)]);

    // Rising diagonal for first: (0,0) (1,1) (2,2) (3,3).
    b = _drop(start(), [0, 1, 1, 2, 2, 3, 2, 3, 3, 6, 3]);
    expect(b.outcome!.winner, Side.first);
    expect(b.winningLine, [(0, 0), (1, 1), (2, 2), (3, 3)]);

    // Falling diagonal for first: (3,3) (4,2) (5,1) (6,0).
    b = _drop(start(), [6, 5, 5, 4, 4, 3, 4, 3, 3, 0, 3]);
    expect(b.outcome!.winner, Side.first);
    expect(b.outcome!.reason, 'line');
    expect(b.winningLine, [(3, 3), (4, 2), (5, 1), (6, 0)]);
  });

  test('full board with no four is a draw (full)', () {
    // Found by search: a full game in which nobody ever makes four.
    const order = [
      0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 2, 2, 4, 3, 3, 3, 3, //
      3, 3, 4, 4, 4, 4, 4, 5, 5, 5, 5, 5, 5, 6, 6, 6, 6, 6, 6,
    ];
    var b = start();
    for (final c in order) {
      expect(b.outcome, isNull, reason: 'ended early at col $c');
      b = b.play({'col': c})! as FourInARowBoard;
    }
    expect(b.winningLine, isNull);
    expect(b.outcome!.winner, isNull);
    expect(b.outcome!.reason, 'full');
    expect(b.play({'col': 0}), isNull);
  });

  test('no play after outcome', () {
    final b = _drop(start(), [0, 1, 0, 1, 0, 1, 0]);
    expect(b.play({'col': 2}), isNull);
  });

  test('fromWire still maps tictactoe, checkers, chess and fourinarow', () {
    expect(GameType.fromWire('tictactoe'), GameType.tictactoe);
    expect(GameType.fromWire('checkers'), GameType.checkers);
    expect(GameType.fromWire('chess'), GameType.chess);
    expect(GameType.fromWire('fourinarow'), GameType.fourinarow);
    expect(GameType.fourinarow.title, 'Four in a Row');
    expect(initialBoard(GameType.fourinarow), isA<FourInARowBoard>());
  });
}
