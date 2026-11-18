import 'package:famchat/games/reversi.dart';
import 'package:famchat/games/rules.dart';
import 'package:flutter_test/flutter_test.dart';

ReversiBoard start() => ReversiBoard.initial();

void main() {
  test('start position: 28 and 35 second, 27 and 36 first; first to move '
      'with 4 legal cells', () {
    final b = start();
    expect(b.at(28), Side.second);
    expect(b.at(35), Side.second);
    expect(b.at(27), Side.first);
    expect(b.at(36), Side.first);
    expect(b.counts, (2, 2));
    expect(b.toMove, Side.first);
    expect(b.outcome, isNull);
    expect(b.drawOffers, isFalse);
    expect(b.lastCell, isNull);
    expect(b.legalCells(), [20, 29, 34, 43]);
  });

  test('a move flips every bracketed line', () {
    // Mover (first) plays 27. East: 28 second, 29 first. South: 35 second,
    // 43 first. South-east: 36 second, 45 first. West: 26 first (adjacent).
    final b = ReversiBoard.custom({
      28: Side.second,
      29: Side.first,
      35: Side.second,
      43: Side.first,
      36: Side.second,
      45: Side.first,
      26: Side.first,
    }, Side.first);
    final n = b.play({'cell': 27})! as ReversiBoard;
    for (final i in [27, 28, 29, 35, 43, 36, 45, 26]) {
      expect(n.at(i), Side.first, reason: 'cell $i');
    }
    expect(n.counts, (8, 0));
    expect(n.lastCell, 27);
    expect(b.at(28), Side.second, reason: 'original untouched');
  });

  test('a cell that flips nothing is illegal', () {
    final b = start();
    expect(b.play({'cell': 0}), isNull);
    expect(b.play({'cell': 26}), isNull);
    expect(b.play({'cell': 19}), isNull);
  });

  test('occupied or out-of-range cell returns null', () {
    final b = start();
    expect(b.play({'cell': 27}), isNull);
    expect(b.play({'cell': 28}), isNull);
    expect(b.play({'cell': -1}), isNull);
    expect(b.play({'cell': 64}), isNull);
    expect(b.play({'cell': '29'}), isNull);
    expect(b.play({'cell': 29.0}), isNull);
    expect(b.play({'cell': null}), isNull);
    expect(b.play({}), isNull);
  });

  test('play flips a line and passes the turn', () {
    final n = start().play({'cell': 29})! as ReversiBoard;
    expect(n.at(28), Side.first);
    expect(n.at(29), Side.first);
    expect(n.counts, (4, 1));
    expect(n.toMove, Side.second);
  });

  test('side with no move passes automatically', () {
    // First captures 2's only disc; second then has no move, first does.
    final b = ReversiBoard.custom({
      0: Side.first,
      1: Side.second,
      40: Side.first,
      41: Side.second,
    }, Side.first);
    expect(b.toMove, Side.first);
    final n = b.play({'cell': 2})! as ReversiBoard;
    expect(n.at(1), Side.first);
    // Second has no discs left that can bracket anything, first still can
    // play 42 (flips 41), so the turn comes straight back.
    expect(n.toMove, Side.first);
    expect(n.outcome, isNull);
    expect(n.legalCells(), [42]);
  });

  test('a position whose nominal mover is stuck hands the turn over', () {
    final b = ReversiBoard.custom({0: Side.first, 1: Side.second}, Side.second);
    expect(b.toMove, Side.first);
    expect(b.legalCells(), [2]);
  });

  test('game ends when neither side can move', () {
    final b = ReversiBoard.custom({
      0: Side.first,
      1: Side.second,
      40: Side.first,
      41: Side.second,
    }, Side.first);
    final n = b.play({'cell': 2})! as ReversiBoard;
    final done = n.play({'cell': 42})! as ReversiBoard;
    expect(done.outcome, isNotNull);
    expect(done.legalCells(), isEmpty);
    expect(done.play({'cell': 63}), isNull);
    expect(done.counts, (6, 0));
  });

  test('more discs wins with reason discs', () {
    final b = ReversiBoard.custom({
      0: Side.first,
      1: Side.first,
      63: Side.second,
    }, Side.first);
    expect(b.outcome!.winner, Side.first);
    expect(b.outcome!.reason, 'discs');
    final w = ReversiBoard.custom({
      0: Side.second,
      1: Side.second,
      63: Side.first,
    }, Side.first);
    expect(w.outcome!.winner, Side.second);
  });

  test('equal discs is a draw', () {
    final b = ReversiBoard.custom({0: Side.first, 7: Side.second}, Side.first);
    expect(b.outcome!.winner, isNull);
    expect(b.outcome!.reason, 'discs');
  });

  test('replaying the same moves is deterministic', () {
    Board run() {
      Board b = start();
      for (final c in [29, 21, 13]) {
        b = b.play({'cell': c}) ?? b;
      }
      return b;
    }

    final a = run() as ReversiBoard, b = run() as ReversiBoard;
    expect(
      [for (var i = 0; i < 64; i++) a.at(i)],
      [for (var i = 0; i < 64; i++) b.at(i)],
    );
    expect(a.toMove, b.toMove);
  });
}
