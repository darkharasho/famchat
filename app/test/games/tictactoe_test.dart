import 'package:famchat/games/rules.dart';
import 'package:famchat/games/tictactoe.dart';
import 'package:flutter_test/flutter_test.dart';

Board _play(Board b, List<int> cells) {
  var cur = b;
  for (final c in cells) {
    cur = cur.play({'cell': c})!;
  }
  return cur;
}

void main() {
  Board start() => initialBoard(GameType.tictactoe);

  test('first player moves first', () {
    final b = start();
    expect(b.toMove, Side.first);
    expect(b.outcome, isNull);
    expect(b.drawOffers, isFalse);
  });

  test('play fills a cell and passes the turn', () {
    final b = start();
    final n = b.play({'cell': 4})! as TicTacToeBoard;
    expect(n.cells[4], Side.first);
    expect(n.toMove, Side.second);
    expect((b as TicTacToeBoard).cells[4], isNull);
  });

  test('occupied, out-of-range or non-int cell returns null', () {
    final b = _play(start(), [4]);
    expect(b.play({'cell': 4}), isNull);
    expect(b.play({'cell': 9}), isNull);
    expect(b.play({'cell': -1}), isNull);
    expect(b.play({'cell': '1'}), isNull);
    expect(b.play({'cell': 1.5}), isNull);
    expect(b.play({}), isNull);
  });

  test('three in a row wins with reason line and winningLine [0,4,8]', () {
    final b = _play(start(), [0, 1, 4, 2, 8]) as TicTacToeBoard;
    expect(b.outcome!.winner, Side.first);
    expect(b.outcome!.reason, 'line');
    expect(b.winningLine, [0, 4, 8]);
  });

  test('full board with no line is a draw (reason full)', () {
    final b = _play(start(), [0, 1, 2, 4, 3, 5, 7, 6, 8]) as TicTacToeBoard;
    expect(b.outcome!.winner, isNull);
    expect(b.outcome!.reason, 'full');
    expect(b.winningLine, isNull);
  });

  test('no play after outcome', () {
    final b = _play(start(), [0, 1, 4, 2, 8]);
    expect(b.play({'cell': 3}), isNull);
  });

  test("GameType.fromWire round-trips and rejects 'go'", () {
    for (final t in GameType.values) {
      expect(GameType.fromWire(t.wire), t);
    }
    expect(GameType.fromWire('go'), isNull);
  });
}
