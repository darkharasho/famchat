import 'package:famchat/games/chess_board.dart';
import 'package:famchat/games/rules.dart';
import 'package:flutter_test/flutter_test.dart';

ChessBoard _start() => initialBoard(GameType.chess) as ChessBoard;

ChessBoard _play(ChessBoard b, List<String> ucis) {
  var board = b;
  for (final u in ucis) {
    final next = board.play({'uci': u});
    expect(next, isNotNull, reason: 'move $u should be legal');
    board = next!;
  }
  return board;
}

void main() {
  test('opening position', () {
    final b = _start();
    expect(b.toMove, Side.first);
    expect(b.outcome, isNull);
    expect(b.drawOffers, isTrue);
    expect(b.lastMove, isNull);
    expect(b.inCheck, isFalse);
    expect(b.at('e1')?.side, Side.first);
    expect(b.at('e1')?.role, ChessRole.king);
    expect(b.at('d8')?.side, Side.second);
    expect(b.at('d8')?.role, ChessRole.queen);
    expect(b.at('b1')?.role, ChessRole.knight);
    expect(b.at('c8')?.role, ChessRole.bishop);
    expect(b.at('h8')?.role, ChessRole.rook);
    expect(b.at('a7')?.role, ChessRole.pawn);
    expect(b.at('e4'), isNull);
    expect(b.at('zz'), isNull);
    expect(b.at('e44'), isNull);
  });

  test('white moves first; e2e4 legal, e2e5 null', () {
    final b = _start();
    expect(b.play({'uci': 'e2e5'}), isNull);
    final n = b.play({'uci': 'e2e4'})!;
    expect(n.toMove, Side.second);
    expect(n.lastMove, ('e2', 'e4'));
    expect(n.at('e4')?.role, ChessRole.pawn);
    expect(n.at('e2'), isNull);
    // Black cannot move a white piece, and white cannot move twice.
    expect(n.play({'uci': 'd2d4'}), isNull);
    expect(b.play({'uci': 'e7e5'}), isNull);
  });

  test('play does not mutate the board', () {
    final b = _start();
    b.play({'uci': 'e2e4'});
    expect(b.toMove, Side.first);
    expect(b.at('e2')?.role, ChessRole.pawn);
    expect(b.at('e4'), isNull);
    expect(b.lastMove, isNull);
  });

  test('malformed uci returns null', () {
    final b = _start();
    for (final m in <Map<String, Object?>>[
      {'uci': 'zz'},
      {'uci': 'e2'},
      {'uci': 42},
      {'uci': null},
      {},
      {'uci': ''},
      {'uci': 'e2e4e5'},
      {'uci': 'e2e4 '},
      {'uci': 'E2E4'},
      {'uci': 'e2i4'},
      {'uci': 'e0e4'},
      {'uci': 'e2e9'},
      {'from': 'e2', 'to': 'e4'},
    ]) {
      expect(b.play(m), isNull, reason: '$m');
    }
  });

  test('a promotion suffix on a non-promotion move is rejected', () {
    final b = _start();
    for (final s in ['q', 'r', 'b', 'n']) {
      expect(b.play({'uci': 'e2e4$s'}), isNull);
    }
    expect(b.needsPromotion('e2', 'e4'), isFalse);
  });

  test("fool's mate: f2f3 e7e5 g2g4 d8h4 is checkmate for second", () {
    final b = _play(_start(), ['f2f3', 'e7e5', 'g2g4', 'd8h4']);
    expect(b.inCheck, isTrue);
    expect(b.outcome?.winner, Side.second);
    expect(b.outcome?.reason, 'checkmate');
    expect(b.lastMove, ('d8', 'h4'));
  });

  test('castling e1g1 is legal after clearing f1 and g1', () {
    final start = _start();
    expect(start.play({'uci': 'e1g1'}), isNull);
    final b = _play(start, ['e2e4', 'e7e5', 'g1f3', 'b8c6', 'f1c4', 'g8f6']);
    expect(b.targetsFrom('e1'), containsAll(['f1', 'g1']));
    final c = b.play({'uci': 'e1g1'})!;
    expect(c.at('g1')?.role, ChessRole.king);
    expect(c.at('f1')?.role, ChessRole.rook);
    expect(c.at('h1'), isNull);
    expect(c.at('e1'), isNull);
  });

  test('en passant', () {
    final b = _play(_start(), ['e2e4', 'a7a6', 'e4e5', 'd7d5']);
    expect(b.targetsFrom('e5'), containsAll(['d6', 'e6']));
    final c = b.play({'uci': 'e5d6'})!;
    expect(c.at('d6')?.side, Side.first);
    expect(c.at('d6')?.role, ChessRole.pawn);
    expect(c.at('d5'), isNull);
    expect(c.at('e5'), isNull);
    // Only immediately after the double step.
    final late = _play(_start(), ['e2e4', 'd7d5', 'e4e5', 'a7a6', 'a2a3']);
    expect(late.play({'uci': 'e5d6'}), isNull);
  });

  test('promotion requires a suffix', () {
    final b = ChessBoard.fromFen('8/P7/8/8/8/8/8/k6K w - - 0 1');
    expect(b.needsPromotion('a7', 'a8'), isTrue);
    expect(b.needsPromotion('h1', 'h2'), isFalse);
    expect(b.needsPromotion('a7', 'a6'), isFalse);
    expect(b.targetsFrom('a7'), ['a8']);
    expect(b.play({'uci': 'a7a8'}), isNull);
    expect(b.play({'uci': 'a7a8k'}), isNull);
    expect(b.play({'uci': 'a7a8p'}), isNull);
    expect(b.play({'uci': 'a7a8Q'}), isNull);
    final q = b.play({'uci': 'a7a8q'})!;
    expect(q.at('a8')?.role, ChessRole.queen);
    expect(q.at('a8')?.side, Side.first);
    expect(q.at('a7'), isNull);
    final n = b.play({'uci': 'a7a8n'})!;
    expect(n.at('a8')?.role, ChessRole.knight);
  });

  test('stalemate is a draw', () {
    final b = ChessBoard.fromFen('7k/8/6K1/8/8/8/8/5Q2 w - - 0 1');
    expect(b.outcome, isNull);
    final s = b.play({'uci': 'f1f7'})!;
    expect(s.inCheck, isFalse);
    expect(s.outcome?.winner, isNull);
    expect(s.outcome?.reason, 'stalemate');
  });

  test('threefold repetition via Nf3 Nf6 Ng1 Ng8 twice', () {
    const cycle = ['g1f3', 'g8f6', 'f3g1', 'f6g8'];
    final almost = _play(_start(), [...cycle, ...cycle.take(3)]);
    expect(almost.outcome, isNull);
    final b = _play(almost, [cycle.last]);
    expect(b.outcome?.winner, isNull);
    expect(b.outcome?.reason, 'threefold');
  });

  test('king against king is insufficient material', () {
    final b = ChessBoard.fromFen('8/8/8/8/8/8/1q6/K6k w - - 0 1');
    expect(b.outcome, isNull);
    final k = b.play({'uci': 'a1b2'})!;
    expect(k.outcome?.winner, isNull);
    expect(k.outcome?.reason, 'insufficient');
  });

  test('fifty-move rule', () {
    final b = ChessBoard.fromFen('8/8/8/8/8/8/6R1/k6K w - - 99 80');
    expect(b.outcome, isNull);
    final f = b.play({'uci': 'g2g3'})!;
    expect(f.outcome?.winner, isNull);
    expect(f.outcome?.reason, 'fifty_moves');
  });

  test('targetsFrom only lists moves for the side to move', () {
    final b = _start();
    expect(b.targetsFrom('e2'), ['e3', 'e4']);
    expect(b.targetsFrom('g1'), unorderedEquals(['f3', 'h3']));
    expect(b.targetsFrom('e7'), isEmpty);
    expect(b.targetsFrom('e4'), isEmpty);
    expect(b.targetsFrom('e1'), isEmpty);
    expect(b.targetsFrom('zz'), isEmpty);
    expect(b.targetsFrom(''), isEmpty);
  });

  test('a promoted piece on an earlier board survives later replays', () {
    // The package's undo (used for repetition checks) rewrites piece types;
    // boards must not share mutable pieces.
    final promoted = ChessBoard.fromFen('8/P7/8/8/8/8/8/k6K w - - 0 1')
        .play({'uci': 'a7a8q'})!;
    final later = _play(promoted, ['a1b1', 'h1g1']);
    expect(later.outcome, isNull);
    expect(promoted.at('a8')?.role, ChessRole.queen);
    expect(later.at('a8')?.role, ChessRole.queen);
    expect(promoted.targetsFrom('a8'), isEmpty); // black to move
    final again = promoted.play({'uci': 'a1b2'})!;
    expect(again.targetsFrom('a8'), contains('h8'));
  });

  test('castling rights on a board survive a sibling line moving the king', () {
    final b = _play(_start(), ['e2e4', 'e7e5', 'g1f3', 'b8c6', 'f1c4', 'g8f6']);
    final sibling = _play(b, ['e1e2', 'f8c5']);
    expect(sibling.outcome, isNull);
    expect(b.outcome, isNull);
    expect(b.targetsFrom('e1'), contains('g1'));
    expect(b.play({'uci': 'e1g1'}), isNotNull);
  });

  test('replays 200 plies quickly', () {
    final sw = Stopwatch()..start();
    var b = _start();
    var plies = 0;
    const files = 'abcdefgh';
    while (plies < 200 && b.outcome == null) {
      String? uci;
      outer:
      for (var r = 1; r <= 8; r++) {
        for (var f = 0; f < 8; f++) {
          final sq = '${files[f]}$r';
          final targets = b.targetsFrom(sq);
          if (targets.isNotEmpty) {
            final to = targets.first;
            uci = '$sq$to${b.needsPromotion(sq, to) ? 'q' : ''}';
            break outer;
          }
        }
      }
      b = b.play({'uci': uci})!;
      plies++;
    }
    sw.stop();
    expect(plies, greaterThan(0));
    expect(sw.elapsedMilliseconds, lessThan(500));
  });
}
