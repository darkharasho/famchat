import 'package:famchat/games/landlord/landlord.dart';
import 'package:famchat/games/rules.dart';
import 'package:famchat/games/widgets/landlord/landlord_view.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

const first = Side.first, second = Side.second;

LandlordBoard at(int pos, List<(int, int)> rolls, {Map<int, Side> owners = const {}, List<int>? luck}) =>
    LandlordBoard.custom(rng: rollsSeed(rolls), positions: (pos, 0), owners: owners, luck: luck);

void main() {
  test('passing Start then paying tax shows both, in turn', () {
    final before = at(36, [(3, 5)]);
    final m = landlordMotion(before, act(before, 'roll'));
    expect(m.stops[first], [(4, false)]);
    final money = m.money[first]!;
    expect([for (final c in money) c.$2], [200, -200]);
    expect(money[1].$1 - money[0].$1, greaterThanOrEqualTo(1000));
    expect(money[0].$1, lessThan(m.arrivalMs), reason: 'salary as it passes Start');
    expect(money[1].$1, greaterThanOrEqualTo(m.arrivalMs), reason: 'tax once it lands');
  });

  test('rent moves between the players once the token lands', () {
    final before = at(0, [(2, 4)], owners: {6: second});
    final m = landlordMotion(before, act(before, 'roll'));
    final rent = before.rentFor(6, diceTotal: 6);
    expect(m.money[first], [(m.arrivalMs, -rent)]);
    expect(m.money[second], [(m.arrivalMs, rent)]);
  });

  test('Go to Jail: walks onto it, then jumps to jail', () {
    final before = at(25, [(2, 3)]);
    final m = landlordMotion(before, act(before, 'roll'));
    expect(m.stops[first], [(30, false), (10, true)]);
  });

  test('a card to Start: walks to the card, then round to Start', () {
    final before = at(
      3,
      [(1, 3)],
      luck: [
        LandlordCard.luckToStart.index,
        for (var i = 0; i < 16; i++)
          if (i != LandlordCard.luckToStart.index) i,
      ],
    );
    final now = act(before, 'roll');
    expect(now.position(first), 0);
    final m = landlordMotion(before, now);
    expect(m.stops[first], [(7, false), (0, false)]);
    expect(m.cardMs, greaterThan(0));
    expect(m.money[first]!.single.$2, 200);
    expect(m.money[first]!.single.$1, greaterThan(m.cardMs));
  });

  test('a move without a roll changes money at once', () {
    final before = LandlordBoard.custom(owners: {1: first});
    final now = act(before, 'mortgage', {'space': 1});
    final m = landlordMotion(before, now);
    expect(m.stops, isEmpty);
    expect(m.money[first], [(0, 30)]);
  });
}
