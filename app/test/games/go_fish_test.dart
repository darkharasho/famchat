import 'package:famchat/games/go_fish.dart';
import 'package:famchat/games/rng.dart';
import 'package:famchat/games/rules.dart';
import 'package:flutter_test/flutter_test.dart';

/// The card of [rank] (1..13) and [suit] (0..3).
int c(int rank, int suit) => (rank - 1) * 4 + suit;

const first = Side.first, second = Side.second;

GoFishBoard ask(GoFishBoard b, int rank) =>
    b.play({'rank': rank})! as GoFishBoard;

void main() {
  test('deal: 7 each alternating from first, rest is stock', () {
    final deck = shuffled(List.generate(52, (i) => i), Rng(1));
    final b = GoFishBoard.deal(1);
    expect(b.hand(first), [for (var i = 0; i < 14; i += 2) deck[i]]..sort());
    expect(b.hand(second), [for (var i = 1; i < 14; i += 2) deck[i]]..sort());
    expect(b.stockCount, 38);
    expect(b.toMove, first);
    expect(b.drawOffers, false);
    expect(b.outcome, isNull);
    expect(b.events, isEmpty);
  });

  test('a dealt four of a kind is booked at once', () {
    // Seed 304 is the first that deals a four of a kind (found offline).
    for (final s in [for (var i = 0; i < 50; i++) i, 304, 839, 1323]) {
      final b = GoFishBoard.deal(s);
      for (final side in Side.values) {
        final counts = <int, int>{};
        for (final card in b.hand(side)) {
          counts.update(GoFishBoard.rankOf(card), (n) => n + 1, ifAbsent: () => 1);
        }
        expect(counts.values.every((n) => n < 4), isTrue, reason: 'seed $s');
      }
      final cards = b.hand(first).length + b.hand(second).length + b.stockCount;
      final booked = (b.books(first).length + b.books(second).length) * 4;
      expect(cards + booked, 52);
    }
    final b = GoFishBoard.deal(304);
    expect(b.books(first).length + b.books(second).length, 1);
  });

  test('rank and suit of a card', () {
    expect(GoFishBoard.rankOf(0), 1);
    expect(GoFishBoard.rankOf(51), 13);
    expect(GoFishBoard.suitOf(c(12, 2)), 2);
  });

  test('asking for a rank you do not hold is illegal', () {
    final b = GoFishBoard.custom(
      firstHand: [c(7, 0)],
      secondHand: [c(5, 0)],
      stock: [c(2, 0)],
    );
    for (final bad in [5, 0, 14, '7', 7.5, null]) {
      expect(b.play({'rank': bad}), isNull, reason: '$bad');
    }
    expect(b.play({'rank': 7.0}), isNotNull);
  });

  test('match: opponent hands over all of that rank, mover goes again', () {
    final b = ask(
      GoFishBoard.custom(
        firstHand: [c(5, 0), c(7, 0)],
        secondHand: [c(5, 1), c(5, 2), c(9, 0)],
        stock: [c(2, 0)],
      ),
      5,
    );
    expect(b.hand(first), [c(5, 0), c(5, 1), c(5, 2), c(7, 0)]);
    expect(b.hand(second), [c(9, 0)]);
    expect(b.stockCount, 1);
    expect(b.toMove, first);
    final e = b.events.single;
    expect((e.asker, e.rank, e.given, e.drawn, e.again), (first, 5, 2, null, true));
  });

  test('go fish: draws top of stock, turn passes', () {
    final b = ask(
      GoFishBoard.custom(
        firstHand: [c(7, 0)],
        secondHand: [c(9, 0)],
        stock: [c(2, 0), c(3, 0)],
      ),
      7,
    );
    expect(b.hand(first), [c(2, 0), c(7, 0)]);
    expect(b.stockCount, 1);
    expect(b.toMove, second);
    final e = b.events.single;
    expect((e.given, e.drawn, e.again), (0, c(2, 0), false));
  });

  test('lucky draw: drawn card is the asked rank, mover goes again', () {
    final b = ask(
      GoFishBoard.custom(
        firstHand: [c(7, 0)],
        secondHand: [c(9, 0)],
        stock: [c(7, 1), c(3, 0)],
      ),
      7,
    );
    expect(b.toMove, first);
    expect(b.events.single.again, isTrue);
    expect(b.events.single.drawn, c(7, 1));
  });

  test('go fish with empty stock: turn passes, drawn == null', () {
    final b = ask(
      GoFishBoard.custom(firstHand: [c(7, 0)], secondHand: [c(9, 0)], stock: []),
      7,
    );
    expect(b.toMove, second);
    expect(b.events.single.drawn, isNull);
    expect(b.events.single.again, isFalse);
  });

  test('books laid after a play, for either hand', () {
    final b = ask(
      GoFishBoard.custom(
        firstHand: [c(5, 0), c(8, 0)],
        secondHand: [c(5, 1), c(5, 2), c(5, 3), c(9, 0)],
        stock: [c(2, 0)],
      ),
      5,
    );
    expect(b.books(first), [5]);
    expect(b.hand(first), [c(8, 0)]);
    expect(b.events.single.booked, [(first, 5)]);
    expect(b.scores, (1, 0));

    // A go-fish draw can complete a book too.
    final d = ask(
      GoFishBoard.custom(
        firstHand: [c(6, 0), c(6, 1), c(6, 2), c(8, 0)],
        secondHand: [c(9, 0)],
        stock: [c(8, 1), c(6, 3)],
      ),
      6,
    );
    expect(d.books(first), isEmpty);
    expect(d.toMove, second);
    final l = ask(
      GoFishBoard.custom(
        firstHand: [c(6, 0), c(6, 1), c(6, 2), c(8, 0)],
        secondHand: [c(9, 0)],
        stock: [c(6, 3)],
      ),
      6,
    );
    expect(l.books(first), [6]);
    expect(l.toMove, first);
  });

  test('empty hand after a play draws one from stock (mover first, then opponent)', () {
    final b = ask(
      GoFishBoard.custom(
        firstHand: [c(5, 0)],
        secondHand: [c(5, 1), c(5, 2), c(5, 3)],
        stock: [c(2, 0), c(3, 0), c(4, 0)],
      ),
      5,
    );
    expect(b.books(first), [5]);
    expect(b.hand(first), [c(2, 0)]);
    expect(b.hand(second), [c(3, 0)]);
    expect(b.stockCount, 1);
    expect(b.toMove, first);
  });

  test('player to move with no cards and empty stock: toMove is the other player', () {
    final b = GoFishBoard.custom(firstHand: [], secondHand: [c(2, 0)], stock: []);
    expect(b.toMove, second);

    final p = ask(
      GoFishBoard.custom(
        firstHand: [c(5, 0)],
        secondHand: [c(5, 1), c(5, 2), c(5, 3), c(9, 0)],
        stock: [],
      ),
      5,
    );
    expect(p.events.single.again, isTrue);
    expect(p.hand(first), isEmpty);
    expect(p.toMove, second);
  });

  test('ends at 13 books: most books wins, reason books', () {
    final b = GoFishBoard.custom(
      firstHand: [c(13, 0)],
      secondHand: [c(13, 1), c(13, 2), c(13, 3)],
      stock: [],
      firstBooks: [1, 2, 3, 4, 5, 6, 7],
      secondBooks: [8, 9, 10, 11, 12],
    );
    expect(b.outcome, isNull);
    final end = ask(b, 13);
    expect(end.outcome?.winner, first);
    expect(end.outcome?.reason, 'books');
    expect(end.scores, (8, 5));

    final lose = ask(
      GoFishBoard.custom(
        firstHand: [c(13, 0)],
        secondHand: [c(13, 1), c(13, 2), c(13, 3)],
        stock: [],
        firstBooks: [1, 2, 3],
        secondBooks: [4, 5, 6, 7, 8, 9, 10, 11, 12],
      ),
      13,
    );
    expect(lose.outcome?.winner, second);
  });

  test('play after the end is illegal', () {
    final end = ask(
      GoFishBoard.custom(
        firstHand: [c(13, 0)],
        secondHand: [c(13, 1), c(13, 2), c(13, 3)],
        stock: [],
        firstBooks: [1, 2, 3, 4, 5, 6, 7],
        secondBooks: [8, 9, 10, 11, 12],
      ),
      13,
    );
    expect(end.play({'rank': 13}), isNull);
  });

  test('events keep only the last 200', () {
    var b = GoFishBoard.custom(firstHand: [c(2, 0)], secondHand: [c(3, 0)], stock: []);
    for (var i = 0; i < 250; i++) {
      b = ask(b, b.toMove == first ? 2 : 3);
    }
    expect(b.events, hasLength(200));
    expect(b.events.last.asker, second);
    expect(b.events.first.asker, first);
  });

  test('play never mutates the board', () {
    final b = GoFishBoard.custom(
      firstHand: [c(5, 0)],
      secondHand: [c(5, 1)],
      stock: [c(2, 0)],
    );
    ask(b, 5);
    expect(b.hand(first), [c(5, 0)]);
    expect(b.hand(second), [c(5, 1)]);
    expect(b.events, isEmpty);
  });
}
