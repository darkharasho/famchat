import 'package:famchat/games/rules.dart';
import 'package:famchat/games/war.dart';
import 'package:famchat/games/widgets/board_view.dart';
import 'package:famchat/games/widgets/war_view.dart';
import 'package:famchat/theme/app_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// The card of [rank] (1..13) and [suit] (0..3).
int c(int rank, [int suit = 0]) => (rank - 1) * 4 + suit;

void main() {
  group('rules', () {
    test('a deal gives 26 each, every card once; first flips first', () {
      final b = initialBoard(GameType.war, 42) as WarBoard;
      expect(b.deck(Side.first), hasLength(26));
      expect(b.deck(Side.second), hasLength(26));
      expect({...b.deck(Side.first), ...b.deck(Side.second)}, hasLength(52));
      expect(b.toMove, Side.first);
      expect(GameType.war.seeded, isTrue);
      expect(GameType.fromWire('war'), GameType.war);
    });

    test('the higher card takes both; aces are high; turns alternate', () {
      final b = WarBoard.custom([c(1), c(5)], [c(13), c(9)]);
      final one = b.play({'flip': true})! as WarBoard;
      expect(one.won, (2, 0));
      expect(one.toMove, Side.second);
      expect(one.battles.single.winner, Side.first);
      final two = one.play({'flip': true})! as WarBoard;
      expect(two.won, (2, 2));
      expect(two.battles.last.flipper, Side.second);
    });

    test('a tie is a war: three down, then the next flip decides', () {
      final b = WarBoard.custom(
        [c(7), c(2), c(3), c(4), c(10), c(2, 1)],
        [c(7, 1), c(2, 1), c(3, 1), c(4, 1), c(9), c(3, 2)],
      );
      final w = b.play({'flip': true})! as WarBoard;
      final battle = w.battles.single;
      expect(battle.war, isTrue);
      expect(battle.rounds, [(c(7), c(7, 1)), (c(10), c(9))]);
      expect(battle.downs, [3]);
      expect(battle.pot, 10);
      expect(w.won, (10, 0));
      expect(w.deck(Side.first), [c(2, 1)]);
    });

    test('a war short of cards lays what it can, keeping one to flip', () {
      final b = WarBoard.custom([c(7), c(2), c(10)], [c(7, 1), c(2, 1), c(9)]);
      final w = b.play({'flip': true})! as WarBoard;
      expect(w.battles.single.downs, [1]);
      expect(w.won, (6, 0));
      expect(w.outcome?.winner, Side.first);
      expect(w.outcome?.reason, 'cards');
    });

    test('a tie on the last cards: each takes theirs back', () {
      final b = WarBoard.custom([c(4), c(7)], [c(9), c(7, 1)]);
      final one = b.play({'flip': true})! as WarBoard;
      final two = one.play({'flip': true})! as WarBoard;
      expect(two.battles.last.winner, isNull);
      expect(two.won, (1, 3));
      expect(two.outcome?.winner, Side.second);
    });

    test('equal cards won is a draw; bad moves are refused', () {
      final b = WarBoard.custom([c(9)], [c(4)]);
      expect(b.play({}), isNull);
      expect(b.play({'flip': 1}), isNull);
      final done =
          WarBoard.custom(
                [c(4), c(9)],
                [c(9, 1), c(4, 1)],
              ).play({'flip': true})!.play({'flip': true})!
              as WarBoard;
      expect(done.outcome, isNotNull);
      expect(done.outcome!.winner, isNull);
      expect(done.play({'flip': true}), isNull);
    });

    test('a whole game always ends within 26 flips', () {
      for (var seed = 0; seed < 50; seed++) {
        Board b = initialBoard(GameType.war, seed);
        var flips = 0;
        while (b.outcome == null) {
          b = b.play({'flip': true})!;
          flips++;
        }
        expect(flips, lessThanOrEqualTo(26));
        final (x, y) = (b as WarBoard).won;
        expect(x + y, 52);
      }
    });

    test('a plain deal is the same with or without the option off', () {
      final a = initialBoard(GameType.war, 7) as WarBoard;
      final b = initialBoard(GameType.war, 7, false, true) as WarBoard;
      expect(a.wholeDeck, isFalse);
      expect(b.wholeDeck, isTrue);
      expect(b.deck(Side.first), a.deck(Side.first));
      expect(GameType.war.rules, 2);
    });
    test('log lines', () {
      final b =
          WarBoard.custom([c(13)], [c(7, 1)]).play({'flip': true})! as WarBoard;
      expect(
        warLog(b.battles.last, ('You', 'Mom')),
        "Your K♠ beat Mom's 7♥ · +2",
      );
      expect(
        warLog(b.battles.last, ('Mom', 'You')),
        "Mom's K♠ beat your 7♥ · +2",
      );
    });
  });

  group('table', () {
    final theme = buildTheme(Brightness.dark);
    late List<Map<String, Object?>> played;
    setUp(() => played = []);

    Widget view(Board b, {Side? me = Side.first, bool thumbnail = false}) =>
        MaterialApp(
          theme: theme,
          home: Scaffold(
            body: SizedBox(
              width: 390,
              height: 600,
              child: BoardView(
                board: b,
                mySide: me,
                onPlay: played.add,
                thumbnail: thumbnail,
                names: me == Side.second
                    ? const ('Mom', 'You')
                    : const ('You', 'Mom'),
              ),
            ),
          ),
        );

    testWidgets('tapping my deck flips', (tester) async {
      await tester.pumpWidget(view(initialBoard(GameType.war, 1)));
      expect(find.textContaining('Tap your deck'), findsOneWidget);
      await tester.tap(find.byKey(const Key('war-deck-me')));
      expect(played, [
        {'flip': true},
      ]);
      played.clear();
      await tester.tap(find.byKey(const Key('war-deck-them')));
      expect(played, isEmpty);
    });

    testWidgets("not my turn, spectators and thumbnails don't flip", (
      tester,
    ) async {
      final b = initialBoard(GameType.war, 1);
      await tester.pumpWidget(view(b, me: Side.second));
      await tester.tap(find.byKey(const Key('war-deck-me')));
      await tester.pumpWidget(view(b, me: null));
      await tester.tap(
        find.byKey(const Key('war-deck-me')),
        warnIfMissed: false,
      );
      await tester.pumpWidget(view(b, thumbnail: true));
      await tester.tap(
        find.byKey(const Key('war-deck-me')),
        warnIfMissed: false,
      );
      expect(played, isEmpty);
    });

    testWidgets('a battle plays out, then the result is written', (
      tester,
    ) async {
      final b = WarBoard.custom(
        [c(7), c(2), c(3), c(4), c(10), c(2, 1)],
        [c(7, 1), c(2, 1), c(3, 1), c(4, 1), c(9), c(3, 2)],
      );
      final w = b.play({'flip': true})!;
      await tester.pumpWidget(view(b));
      await tester.pumpWidget(view(w));
      await tester.pump(const Duration(milliseconds: 700));
      expect(find.byKey(Key('war-card-${c(7)}')), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('WAR!'), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.text('WAR!'), findsNothing);
      expect(
        find.textContaining("War! Your 10♠ beat Mom's 9♠ · +10"),
        findsOneWidget,
      );
      expect(find.text('Won 10'), findsOneWidget);
    });

    testWidgets('reduced motion shows the result at once', (tester) async {
      final b = WarBoard.custom([c(13), c(2)], [c(7), c(3)]);
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: view(b),
        ),
      );
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: view(b.play({'flip': true})!),
        ),
      );
      await tester.pump();
      expect(tester.hasRunningAnimations, isFalse);
      expect(find.text('Won 2'), findsOneWidget);
    });

    test('score and shape', () {
      final b = WarBoard.custom([c(13)], [c(7)]).play({'flip': true})!;
      expect(boardScore(b), (2, 0));
      expect(boardAspectRatio(b), 3 / 2);
    });
  });

  group('whole deck', () {
    test('an empty deck takes its pile, shuffled; the game goes on', () {
      final b = WarBoard.custom(
        [c(13)],
        [c(2)],
        firstPile: [c(5), c(6)],
        secondPile: [c(3), c(4)],
        wholeDeck: true,
      );
      final one = b.play({'flip': true})! as WarBoard;
      expect(one.outcome, isNull);
      expect(one.deck(Side.first), isEmpty);
      expect(one.pile(Side.first), [c(5), c(6), c(13), c(2)]);
      expect(one.score, (4, 2));
      final two = one.play({'flip': true})! as WarBoard;
      // Both decks were empty: both piles became decks.
      expect(two.held.$1 + two.held.$2, 6);
      expect(two.pile(Side.first).length + two.pile(Side.second).length, 2);
      expect(two.flips, 2);
    });

    test('it ends when one player has every card', () {
      final b = WarBoard.custom([c(13)], [c(2)], wholeDeck: true);
      final done = b.play({'flip': true})! as WarBoard;
      expect(done.outcome!.winner, Side.first);
      expect(done.outcome!.reason, 'cards');
      expect(boardScore(done), (2, 0));
      expect(done.play({'flip': true}), isNull);
    });

    test('a war lays what the shorter hand can; no card to flip loses', () {
      // Second has 2 cards: the tie, then one to flip, no face-down cards.
      final b = WarBoard.custom(
        [c(7), c(2), c(3), c(4), c(5)],
        [c(7, 1), c(13)],
        wholeDeck: true,
      );
      final w = b.play({'flip': true})! as WarBoard;
      expect(w.battles.last.downs, [0]);
      expect(w.battles.last.winner, Side.second);
      expect(w.held, (3, 4));
      // Second has only the tie card: they can't flip again and lose it.
      final short =
          WarBoard.custom(
                [c(7), c(2)],
                [c(7, 1)],
                wholeDeck: true,
              ).play({'flip': true})!
              as WarBoard;
      expect(short.battles.last.winner, Side.first);
      expect(short.outcome!.winner, Side.first);
      expect(short.held, (3, 0));
    });

    test(
      'dealt games end with all 52 cards on one side, the same each time',
      () {
        for (var seed = 0; seed < 40; seed++) {
          WarBoard run() {
            Board b = initialBoard(GameType.war, seed, false, true);
            var flips = 0;
            while (b.outcome == null && flips < 100000) {
              b = b.play({'flip': true})!;
              flips++;
            }
            return b as WarBoard;
          }

          final b = run();
          expect(b.outcome, isNotNull, reason: 'seed $seed');
          expect(b.outcome!.winner, isNotNull);
          expect({b.held.$1, b.held.$2}, {0, 52});
          expect(run().flips, b.flips);
        }
      },
    );
  });
}
