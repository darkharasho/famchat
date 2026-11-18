import 'package:famchat/games/checkers.dart';
import 'package:famchat/games/rules.dart';
import 'package:flutter_test/flutter_test.dart';

const _fm = CheckersSquare(Side.first, CheckersPiece.man);
const _fk = CheckersSquare(Side.first, CheckersPiece.king);
const _sm = CheckersSquare(Side.second, CheckersPiece.man);

void main() {
  CheckersBoard start() => initialBoard(GameType.checkers) as CheckersBoard;

  test('geometry: 0 is (0,0), 4 is (1,1), 31 is (7,7), light squares map '
      'to null', () {
    expect((CheckersBoard.rowOf(0), CheckersBoard.colOf(0)), (0, 0));
    expect((CheckersBoard.rowOf(4), CheckersBoard.colOf(4)), (1, 1));
    expect((CheckersBoard.rowOf(31), CheckersBoard.colOf(31)), (7, 7));
    expect(CheckersBoard.squareAt(0, 0), 0);
    expect(CheckersBoard.squareAt(1, 1), 4);
    expect(CheckersBoard.squareAt(7, 7), 31);
    expect(CheckersBoard.squareAt(0, 1), isNull);
    expect(CheckersBoard.squareAt(1, 0), isNull);
    expect(CheckersBoard.squareAt(-1, 1), isNull);
    expect(CheckersBoard.squareAt(8, 0), isNull);
    expect(CheckersBoard.squareAt(0, 8), isNull);
    for (var sq = 0; sq < 32; sq++) {
      expect(
        CheckersBoard.squareAt(
          CheckersBoard.rowOf(sq),
          CheckersBoard.colOf(sq),
        ),
        sq,
      );
    }
  });

  test('opening position', () {
    final b = start();
    expect(b.toMove, Side.first);
    expect(b.outcome, isNull);
    expect(b.drawOffers, isTrue);
    expect(b.lastPath, isNull);
    for (var sq = 0; sq < 12; sq++) {
      expect(b.at(sq)?.side, Side.first);
      expect(b.at(sq)?.piece, CheckersPiece.man);
    }
    for (var sq = 12; sq < 20; sq++) {
      expect(b.at(sq), isNull);
    }
    for (var sq = 20; sq < 32; sq++) {
      expect(b.at(sq)?.side, Side.second);
    }
  });

  test('opening position has 7 legal paths for first', () {
    expect(start().legalPaths(), [
      [8, 12],
      [9, 12],
      [9, 13],
      [10, 13],
      [10, 14],
      [11, 14],
      [11, 15],
    ]);
  });

  test('simple move [9,13] is legal; [9,14] (not adjacent) → null', () {
    final b = start();
    final n = b.play({
      'path': [9, 13],
    })!;
    expect(n, isA<CheckersBoard>());
    n as CheckersBoard;
    expect(n.at(9), isNull);
    expect(n.at(13)?.side, Side.first);
    expect(n.toMove, Side.second);
    expect(n.lastPath, [9, 13]);
    // Original not mutated.
    expect(b.at(9)?.side, Side.first);
    expect(b.at(13), isNull);
    expect(b.toMove, Side.first);
    expect(
      b.play({
        'path': [9, 14],
      }),
      isNull,
    );
  });

  test('integral doubles in a path read as ints', () {
    expect(
      start().play({
        'path': [9.0, 13.0],
      }),
      isNotNull,
    );
  });

  test('malformed moves → null', () {
    final b = start();
    expect(b.play({}), isNull);
    expect(b.play({'path': 9}), isNull);
    expect(b.play({'path': '9,13'}), isNull);
    expect(b.play({'path': []}), isNull);
    expect(
      b.play({
        'path': [9],
      }),
      isNull,
    );
    expect(
      b.play({
        'path': [9, '13'],
      }),
      isNull,
    );
    expect(
      b.play({
        'path': [9, 13.5],
      }),
      isNull,
    );
    expect(
      b.play({
        'path': [-1, 3],
      }),
      isNull,
    );
    expect(
      b.play({
        'path': [9, 32],
      }),
      isNull,
    );
    expect(
      b.play({
        'path': [21, 17],
      }),
      isNull,
      reason: 'opponent piece',
    );
  });

  test('second moves toward lower rows', () {
    final b =
        start().play({
              'path': [9, 13],
            })!
            as CheckersBoard;
    expect(b.legalPaths(), contains(equals([21, 17])));
    expect(b.legalPaths(), isNot(contains(equals([21, 25]))));
  });

  test('capture is mandatory: a non-capturing path is rejected when a jump '
      'exists', () {
    final b = CheckersBoard.custom({9: _fm, 0: _fm, 13: _sm}, Side.first);
    expect(b.legalPaths(), [
      [9, 18],
    ]);
    expect(
      b.play({
        'path': [9, 12],
      }),
      isNull,
    );
    expect(
      b.play({
        'path': [0, 4],
      }),
      isNull,
    );
    final n =
        b.play({
              'path': [9, 18],
            })!
            as CheckersBoard;
    expect(n.at(13), isNull);
    expect(n.at(9), isNull);
    expect(n.at(18)?.side, Side.first);
    expect(n.toMove, Side.second);
  });

  test('double jump must be completed: a path stopping after the first jump '
      'is rejected', () {
    final b = CheckersBoard.custom({9: _fm, 13: _sm, 22: _sm}, Side.first);
    expect(b.legalPaths(), [
      [9, 18, 27],
    ]);
    expect(
      b.play({
        'path': [9, 18],
      }),
      isNull,
    );
    final n =
        b.play({
              'path': [9, 18, 27],
            })!
            as CheckersBoard;
    expect(n.at(13), isNull);
    expect(n.at(22), isNull);
    expect(n.at(27)?.side, Side.first);
    expect(n.outcome?.winner, Side.first);
    expect(n.outcome?.reason, 'no_moves');
  });

  test('man crowned on far row and move ends even if a further jump '
      'exists', () {
    final b = CheckersBoard.custom({22: _fm, 26: _sm, 25: _sm}, Side.first);
    expect(b.legalPaths(), [
      [22, 29],
    ]);
    expect(
      b.play({
        'path': [22, 29, 21],
      }),
      isNull,
    );
    final n =
        b.play({
              'path': [22, 29],
            })!
            as CheckersBoard;
    expect(n.at(29)?.piece, CheckersPiece.king);
    expect(n.at(29)?.side, Side.first);
    expect(n.at(25)?.side, Side.second);
    expect(n.toMove, Side.second);
  });

  test('man crowned by a simple move', () {
    final b = CheckersBoard.custom({25: _fm, 0: _sm}, Side.first);
    final n =
        b.play({
              'path': [25, 28],
            })!
            as CheckersBoard;
    expect(n.at(28)?.piece, CheckersPiece.king);
  });

  test('king moves backward', () {
    final b = CheckersBoard.custom({18: _fk, 31: _sm}, Side.first);
    expect(b.legalPaths(), [
      [18, 13],
      [18, 14],
      [18, 21],
      [18, 22],
    ]);
    final n =
        b.play({
              'path': [18, 13],
            })!
            as CheckersBoard;
    expect(n.at(13)?.piece, CheckersPiece.king);
  });

  test('king captures backward in a multi-jump', () {
    // King at 18 (4,4) jumps 13 (3,3) to 9 (2,2), then 5 (1,3) to 2 (0,4).
    final b = CheckersBoard.custom({18: _fk, 13: _sm, 5: _sm}, Side.first);
    expect(b.legalPaths(), [
      [18, 9, 2],
    ]);
  });

  test('side with no pieces or no moves loses with no_moves', () {
    final none = CheckersBoard.custom({5: _fm}, Side.second);
    expect(none.outcome?.winner, Side.first);
    expect(none.outcome?.reason, 'no_moves');
    expect(none.legalPaths(), isEmpty);

    // Second's man at 4 (1,1) is blocked by first's men on 0 and 1, and
    // jumps would leave the board.
    final blocked = CheckersBoard.custom({4: _sm, 0: _fm, 1: _fm}, Side.second);
    expect(blocked.legalPaths(), isEmpty);
    expect(blocked.outcome?.winner, Side.first);
    expect(blocked.outcome?.reason, 'no_moves');
    expect(
      blocked.play({
        'path': [4, 0],
      }),
      isNull,
    );
  });
}
