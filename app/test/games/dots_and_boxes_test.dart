import 'package:famchat/games/dots_and_boxes.dart';
import 'package:famchat/games/rules.dart';
import 'package:flutter_test/flutter_test.dart';

DotsAndBoxesBoard start() =>
    initialBoard(GameType.dotsandboxes) as DotsAndBoxesBoard;

DotsAndBoxesBoard play(DotsAndBoxesBoard b, int line) =>
    b.play({'line': line})! as DotsAndBoxesBoard;

void main() {
  test('fresh board: nothing drawn, first to move, 0-0', () {
    final b = start();
    expect(b.toMove, Side.first);
    expect(b.outcome, isNull);
    expect(b.drawOffers, isFalse);
    expect(b.scores, (0, 0));
    expect(b.lastLine, isNull);
    for (var i = 0; i < DotsAndBoxesBoard.lineCount; i++) {
      expect(b.drawn(i), isFalse);
    }
    for (var i = 0; i < 16; i++) {
      expect(b.owner(i), isNull);
    }
  });

  test('line numbering: 0 is the top-left horizontal, 19 the bottom-right '
      'horizontal, 20 the top-left vertical, 39 the bottom-right vertical', () {
    // (top, bottom, left, right)
    expect(DotsAndBoxesBoard.boxLines(0), (0, 4, 20, 21));
    expect(DotsAndBoxesBoard.boxLines(3), (3, 7, 23, 24));
    expect(DotsAndBoxesBoard.boxLines(5), (5, 9, 26, 27));
    expect(DotsAndBoxesBoard.boxLines(12), (12, 16, 35, 36));
    expect(DotsAndBoxesBoard.boxLines(15), (15, 19, 38, 39));
  });

  test('drawing a line passes the turn', () {
    final b = play(start(), 0);
    expect(b.drawn(0), isTrue);
    expect(b.drawer(0), Side.first);
    expect(b.lastLine, 0);
    expect(b.toMove, Side.second);
    final c = play(b, 39);
    expect(c.drawer(39), Side.second);
    expect(c.toMove, Side.first);
    // The original is untouched.
    expect(b.drawn(39), isFalse);
  });

  test('completing a box claims it and the mover goes again', () {
    var b = start();
    for (final l in [0, 4, 20]) {
      b = play(b, l);
    }
    expect(b.toMove, Side.second);
    b = play(b, 21);
    expect(b.owner(0), Side.second);
    expect(b.scores, (0, 1));
    expect(b.toMove, Side.second);
    // Next plain line passes the turn again.
    b = play(b, 10);
    expect(b.toMove, Side.first);
  });

  test('double box gives both boxes and one extra turn', () {
    final b = DotsAndBoxesBoard.custom({0, 4, 20, 1, 5, 22}, {}, Side.first);
    final n = play(b, 21);
    expect(n.owner(0), Side.first);
    expect(n.owner(1), Side.first);
    expect(n.scores, (2, 0));
    expect(n.toMove, Side.first);
    expect(n.lastLine, 21);
  });

  test('drawn or out-of-range line returns null', () {
    final b = play(start(), 7);
    for (final m in <Map<String, Object?>>[
      {'line': 7},
      {'line': -1},
      {'line': 40},
      {'line': '3'},
      {'line': 3.0},
      {'line': null},
      {},
      {'cell': 3},
    ]) {
      expect(b.play(m), isNull, reason: '$m');
    }
  });

  test('all 40 lines drawn ends the game; most boxes wins (boxes); '
      '8-8 is a draw', () {
    final lines = {for (var i = 0; i < 39; i++) i};
    Map<int, Side> owners(int firstCount) => {
      for (var i = 0; i < 15; i++) i: i < firstCount ? Side.first : Side.second,
    };
    // Box 15 is left; line 39 completes it.
    final draw = DotsAndBoxesBoard.custom(lines, owners(8), Side.second);
    expect(draw.outcome, isNull);
    final d = play(draw, 39);
    expect(d.scores, (8, 8));
    expect(d.outcome!.winner, isNull);
    expect(d.outcome!.reason, 'boxes');
    expect(d.play({'line': 0}), isNull);

    final win = play(
      DotsAndBoxesBoard.custom(lines, owners(8), Side.first),
      39,
    );
    expect(win.scores, (9, 7));
    expect(win.outcome!.winner, Side.first);
    expect(win.outcome!.reason, 'boxes');

    final loss = play(
      DotsAndBoxesBoard.custom(lines, owners(5), Side.first),
      39,
    );
    expect(loss.scores, (6, 10));
    expect(loss.outcome!.winner, Side.second);
  });

  test('replaying the same moves gives the same position', () {
    final moves = [0, 4, 20, 21, 1, 5, 22, 30, 39];
    var a = start(), b = start();
    for (final l in moves) {
      a = play(a, l);
      b = play(b, l);
    }
    expect(a.toMove, b.toMove);
    expect(a.scores, b.scores);
    for (var i = 0; i < 16; i++) {
      expect(a.owner(i), b.owner(i));
    }
  });
}
