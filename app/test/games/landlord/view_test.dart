import 'package:famchat/games/landlord/landlord.dart';
import 'package:famchat/games/rules.dart';
import 'package:famchat/games/widgets/board_view.dart';
import 'package:famchat/games/widgets/landlord/landlord_log.dart';
import 'package:famchat/games/widgets/landlord/landlord_view.dart';
import 'package:famchat/theme/app_theme.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

const first = Side.first, second = Side.second;
const names = ('You', 'Mom');

LandlordEvent ev(Side a, LandlordEventKind k, {int? space, int? amount, (int, int)? dice, LandlordCard? card, Side? other}) =>
    LandlordEvent(a, k, space: space, amount: amount, dice: dice, card: card, other: other);

void main() {
  test('log lines', () {
    String l(LandlordEvent e) => landlordLog(e, names);
    expect(l(ev(second, LandlordEventKind.rolled, dice: (4, 3), space: 16)), 'Mom rolled 4+3 → Iris Place');
    expect(l(ev(first, LandlordEventKind.rent, amount: 14, space: 16, other: second)), 'You paid Mom \$14 rent');
    expect(l(ev(second, LandlordEventKind.rent, amount: 1050, space: 21, other: first)), 'Mom paid you \$1,050 rent');
    expect(l(ev(first, LandlordEventKind.bought, space: 21, amount: 220)), 'You bought Linden Square for \$220');
    expect(l(ev(second, LandlordEventKind.declined, space: 13)), 'Mom passed on Garden Road');
    expect(l(ev(second, LandlordEventKind.drew, card: LandlordCard.luckBack3)), 'Mom drew Luck: Go back 3 spaces');
    expect(l(ev(first, LandlordEventKind.drew, card: LandlordCard.fundPay100)), 'You drew Family Fund: The roof sprang a leak: pay \$100');
    expect(l(ev(second, LandlordEventKind.jailed)), 'Mom went to jail');
    expect(l(ev(first, LandlordEventKind.built, space: 39, amount: 200)), 'You built on Vista Heights');
    expect(l(ev(second, LandlordEventKind.mortgaged, space: 1, amount: 30)), 'Mom mortgaged Acorn Lane for \$30');
    expect(l(ev(second, LandlordEventKind.accepted, other: first)), 'Trade accepted');
    expect(l(ev(second, LandlordEventKind.rejected)), 'Trade rejected');
    expect(l(ev(first, LandlordEventKind.owes, amount: 200, other: second)), 'You owe Mom \$200');
    expect(l(ev(second, LandlordEventKind.owes, amount: 200)), 'Mom owes the bank \$200');
    expect(l(ev(second, LandlordEventKind.bankrupt)), 'Mom went bankrupt');
    // Every kind has a line.
    for (final k in LandlordEventKind.values) {
      expect(l(ev(first, k, space: 1, amount: 5, dice: (1, 2), card: LandlordCard.luckCollect50)), isNotEmpty, reason: '$k');
    }
  });

  test('sinceMyLast', () {
    final es = [ev(first, LandlordEventKind.endTurn), ev(second, LandlordEventKind.jailed), ev(second, LandlordEventKind.endTurn)];
    expect(sinceMyLast(es, first), es.sublist(1));
    expect(sinceMyLast(es, second), isEmpty);
    expect(sinceMyLast(es.sublist(1), first), es.sublist(1));
  });

  group('view', () {
    late List<Map<String, Object?>> played;
    setUp(() => played = []);

    Widget host(Widget child, {double size = 400, Brightness b = Brightness.light}) => MaterialApp(
      theme: buildTheme(b),
      home: Scaffold(body: Center(child: SizedBox(width: size, height: size, child: child))),
    );

    Widget view(LandlordBoard board, {Side? mySide = first, bool interactive = true, bool thumbnail = false, double size = 400, Brightness b = Brightness.light}) => host(
      LandlordView(board: board, mySide: mySide, onPlay: played.add, interactive: interactive, thumbnail: thumbnail, names: mySide == second ? ('Mom', 'You') : names),
      size: size,
      b: b,
    );

    final anySpace = find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('space-'));

    testWidgets('the ring has 40 spaces and fits at any size', (tester) async {
      for (final size in [320.0, 800.0]) {
        for (final b in Brightness.values) {
          tester.view.physicalSize = Size(size + 100, size + 100);
          tester.view.devicePixelRatio = 1;
          await tester.pumpWidget(view(LandlordBoard.setup(1), size: size, b: b));
          expect(anySpace, findsNWidgets(40));
          expect(tester.takeException(), isNull);
        }
      }
      addTearDown(tester.view.reset);
    });

    testWidgets('roll', (tester) async {
      await tester.pumpWidget(view(LandlordBoard.setup(1)));
      await tester.tap(find.byKey(const Key('act-roll')));
      expect(played, [{'a': 'roll'}]);
    });

    testWidgets('buy or not', (tester) async {
      final b = act(LandlordBoard.custom(rng: rollsSeed([(2, 4)])), 'roll');
      await tester.pumpWidget(view(b));
      expect(find.text('Buy for \$100'), findsOneWidget);
      expect(find.text("Don't buy"), findsOneWidget);
      await tester.tap(find.byKey(const Key('act-decline')));
      expect(played, [{'a': 'decline'}]);
    });

    testWidgets('a trade offer to me: accept or reject', (tester) async {
      final b = act(LandlordBoard.custom(owners: {1: first, 6: second}), 'offer', {'give': {'spaces': [1]}, 'get': {'spaces': [6]}});
      await tester.pumpWidget(view(b, mySide: second));
      expect(find.text('Mom offers a trade'), findsOneWidget);
      expect(find.textContaining('Acorn Lane'), findsWidgets);
      await tester.tap(find.byKey(const Key('act-accept')));
      expect(played, [{'a': 'accept'}]);
    });

    testWidgets('no action buttons when it is not my move', (tester) async {
      await tester.pumpWidget(view(LandlordBoard.setup(1), mySide: second));
      final anyAct = find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('act-'));
      expect(anyAct, findsNothing);
      expect(find.text("Mom's turn"), findsOneWidget);
    });

    testWidgets('end turn and a debt', (tester) async {
      final ended = act(act(LandlordBoard.custom(rng: rollsSeed([(2, 4)])), 'roll'), 'buy');
      await tester.pumpWidget(view(ended));
      await tester.tap(find.byKey(const Key('act-end_turn')));
      expect(played, [{'a': 'end_turn'}]);
      final debt = act(LandlordBoard.custom(rng: rollsSeed([(1, 2)]), positions: (36, 0), cash: (100, 1500), owners: {39: second, 1: first, 3: first, 6: first}, levels: {39: 1}), 'roll');
      await tester.pumpWidget(view(debt));
      expect(find.textContaining('You owe Mom \$200'), findsWidgets);
      expect(find.byKey(const Key('act-bankrupt')), findsOneWidget);
      await tester.tap(find.byKey(const Key('act-raise')));
      await tester.pumpAndSettle();
      expect(find.text('Acorn Lane'), findsOneWidget, reason: 'the properties sheet');
      // Each property shows what it raises, and raises it from the list.
      final acorn = find.byKey(const ValueKey('owned-1'));
      expect(find.descendant(of: acorn, matching: find.text('Mortgage value \$30')), findsOneWidget);
      expect(find.descendant(of: acorn, matching: find.text('Mortgage +\$30')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('raise-1')));
      await tester.pump();
      expect(played.last, {'a': 'mortgage', 'space': 1});
      expect(find.byKey(const ValueKey('raise-1')), findsNothing, reason: 'mortgaged now');
      expect(find.descendant(of: acorn, matching: find.text('Mortgaged')), findsOneWidget);
      expect(find.textContaining('You · \$130'), findsOneWidget, reason: 'the cash keeps up');
    });

    testWidgets('passing Start then tax: +\$200, then −\$200, after the token moves', (tester) async {
      final before = LandlordBoard.custom(rng: rollsSeed([(3, 5)]), positions: (36, 0));
      await tester.pumpWidget(view(before));
      await tester.pumpWidget(view(act(before, 'roll')));
      final m = landlordMotion(before, act(before, 'roll'));
      final (gain, loss) = (m.money[first]![0].$1, m.money[first]![1].$1);
      await tester.pump(Duration(milliseconds: gain - 50));
      expect(find.text('+\$200'), findsNothing, reason: 'not before the token passes Start');
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('+\$200'), findsOneWidget);
      await tester.pump(Duration(milliseconds: loss - gain));
      expect(find.text('−\$200'), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.text('\$1,500'), findsWidgets);
    });

    testWidgets('a tap right after the board changes is ignored', (tester) async {
      final rolled = act(LandlordBoard.custom(rng: rollsSeed([(2, 4)])), 'roll');
      await tester.pumpWidget(view(LandlordBoard.custom(rng: rollsSeed([(2, 4)]))));
      await tester.pumpWidget(view(act(rolled, 'buy')));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.byKey(const Key('act-end_turn')), warnIfMissed: false);
      expect(played, isEmpty);
      await tester.pump(const Duration(milliseconds: 700));
      await tester.tap(find.byKey(const Key('act-end_turn')));
      expect(played, [{'a': 'end_turn'}]);
    });

    testWidgets('while you were away: the last 3 and a link to the rest', (tester) async {
      var b = LandlordBoard.custom(owners: {1: first, 3: first, 6: first, 8: first, 9: first});
      for (final s in [1, 3, 6, 8, 9]) {
        b = act(b, 'mortgage', {'space': s});
      }
      await tester.pumpWidget(view(b, mySide: second));
      expect(find.text('While you were away'), findsOneWidget);
      expect(find.textContaining('Mom mortgaged'), findsNWidgets(3));
      await tester.tap(find.byKey(const Key('away-more')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Mom mortgaged Acorn Lane'), findsOneWidget);
    });

    testWidgets('a space sheet offers only legal actions', (tester) async {
      final b = LandlordBoard.custom(owners: {1: first, 6: first});
      await tester.pumpWidget(view(b));
      await tester.tap(find.byKey(const Key('space-1')));
      await tester.pumpAndSettle();
      expect(find.text('Acorn Lane'), findsWidgets);
      expect(find.widgetWithText(FilledButton, 'Mortgage'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Build'), findsNothing);
      await tester.tap(find.widgetWithText(FilledButton, 'Mortgage'));
      await tester.pumpAndSettle();
      expect(played, [{'a': 'mortgage', 'space': 1}]);
    });

    testWidgets('the trade sheet sends a valid offer', (tester) async {
      final b = LandlordBoard.custom(owners: {1: first, 6: second});
      await tester.pumpWidget(view(b));
      await tester.tap(find.byKey(const Key('open-trade')));
      await tester.pumpAndSettle();
      final send = find.byKey(const Key('trade-send'));
      await tester.enterText(find.byKey(const Key('give-cash')), '500');
      await tester.pump();
      expect(tester.widget<FilledButton>(send).onPressed, isNotNull, reason: 'cash alone is an offer');
      await tester.enterText(find.byKey(const Key('give-cash')), '0');
      await tester.pump();
      expect(tester.widget<FilledButton>(send).onPressed, isNull);
      await tester.tap(find.byKey(const Key('give-1')));
      await tester.tap(find.byKey(const Key('get-6')));
      await tester.pump();
      expect(tester.widget<FilledButton>(send).onPressed, isNotNull);
      await tester.tap(send);
      await tester.pumpAndSettle();
      expect(played, [
        {'a': 'offer', 'give': {'cash': 0, 'spaces': [1], 'cards': 0}, 'get': {'cash': 0, 'spaces': [6], 'cards': 0}},
      ]);
    });

    testWidgets('a card drawn this turn is shown face up', (tester) async {
      final luck = [LandlordCard.luckBack3.index, for (var i = 0; i < 16; i++) if (i != LandlordCard.luckBack3.index) i];
      final b = act(LandlordBoard.custom(rng: rollsSeed([(1, 2)]), positions: (4, 0), luck: luck), 'roll');
      await tester.pumpWidget(view(b));
      await tester.pumpAndSettle();
      expect(find.text('Go back 3 spaces'), findsOneWidget);
      await tester.pumpWidget(view(act(b, 'end_turn')));
      await tester.pumpAndSettle();
      expect(find.text('Go back 3 spaces'), findsNothing, reason: 'gone once the turn ends');
    });

    testWidgets('after a roll the token walks to its space', (tester) async {
      final before = LandlordBoard.custom(rng: rollsSeed([(2, 4)]));
      await tester.pumpWidget(view(before));
      await tester.pumpWidget(view(act(before, 'roll')));
      final token = find.byKey(const ValueKey('token-first'));
      final dest = tester.getRect(find.byKey(const Key('space-6')));
      await tester.pump(const Duration(milliseconds: 700));
      expect(dest.contains(tester.getCenter(token)), isFalse, reason: 'still on the way');
      await tester.pumpAndSettle();
      expect(dest.contains(tester.getCenter(token)), isTrue);
    });

    testWidgets('the dice are thrown in, even on the first roll', (tester) async {
      final before = LandlordBoard.custom(rng: rollsSeed([(2, 4)]));
      await tester.pumpWidget(view(before));
      await tester.pumpWidget(view(act(before, 'roll')));
      final die = find.descendant(of: find.bySemanticsLabel('Dice: 2 and 4'), matching: find.byType(CustomPaint)).first;
      await tester.pump(const Duration(milliseconds: 200));
      final midAir = tester.getCenter(die);
      await tester.pumpAndSettle();
      final landed = tester.getCenter(die);
      expect(midAir.dy, lessThan(landed.dy - 10), reason: 'in the air');
      expect(midAir.dx, lessThan(landed.dx - 10), reason: 'thrown in from the left');
    });

    testWidgets('a thumbnail has no ring', (tester) async {
      await tester.pumpWidget(view(LandlordBoard.setup(1), thumbnail: true));
      expect(anySpace, findsNothing);
      expect(find.textContaining('\$1,500'), findsWidgets);
    });

    testWidgets('upcoming cards are never shown', (tester) async {
      final b = LandlordBoard.setup(1);
      await tester.pumpWidget(view(b));
      for (final d in LandlordDeck.values) {
        final next = LandlordCard.values[b.deck(d).first].text;
        expect(find.textContaining(next), findsNothing);
      }
    });

    testWidgets('BoardView shows Landlord', (tester) async {
      await tester.pumpWidget(host(BoardView(board: LandlordBoard.setup(1), mySide: first, onPlay: played.add)));
      expect(find.byType(LandlordView), findsOneWidget);
    });
  });
}
