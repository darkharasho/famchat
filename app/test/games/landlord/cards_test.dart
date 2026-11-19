import 'package:famchat/games/landlord/landlord.dart';
import 'package:famchat/games/rules.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

const first = Side.first, second = Side.second;

/// First lands on card space [at] (rolling 1+2 from at-3) with card [id] on
/// top of its deck, then any [more] rolls follow.
LandlordBoard draw(
  int at,
  int id, {
  Map<int, Side> owners = const {},
  Map<int, int> levels = const {},
  List<(int, int)> more = const [],
  (int, int) cash = (1500, 1500),
}) {
  final luck = id < 16;
  final rest = [for (var i = luck ? 0 : 16; i < (luck ? 16 : 32); i++) if (i != id) i];
  final b = LandlordBoard.custom(
    rng: rollsSeed([(1, 2), ...more]),
    positions: (at - 3, 0),
    owners: owners,
    levels: levels,
    cash: cash,
    luck: luck ? [id, ...rest] : null,
    fund: luck ? null : [id, ...rest],
  );
  return act(b, 'roll');
}

void main() {
  test('a drawn card goes to the bottom and is logged', () {
    final b = draw(7, 6);
    expect(b.deck(LandlordDeck.luck).last, 6);
    expect(b.deck(LandlordDeck.luck), hasLength(16));
    expect(b.events.any((e) => e.kind == LandlordEventKind.drew && e.card == LandlordCard.luckCollect50), isTrue);
  });

  test('advance to Start', () {
    for (final (at, id) in [(7, 0), (17, 16)]) {
      final b = draw(at, id);
      expect(b.position(first), 0);
      expect(b.cash(first), 1700);
    }
  });

  test('advance to Nettle Street and Fern Court', () {
    var b = draw(7, 1);
    expect((b.position(first), b.cash(first), b.phase), (24, 1500, LandlordPhase.buy));
    b = draw(36, 2);
    expect((b.position(first), b.cash(first)), (11, 1700));
    b = draw(7, 2, owners: {11: second});
    expect(b.cash(second), 1510, reason: 'rent on arrival');
  });

  test('nearest utility; owned pays 10x a fresh roll', () {
    expect(draw(7, 3).position(first), 12);
    expect(draw(22, 3).position(first), 28);
    final w = draw(36, 3);
    expect((w.position(first), w.cash(first), w.phase), (12, 1700, LandlordPhase.buy));
    final o = draw(7, 3, owners: {12: second}, more: [(4, 5)]);
    expect(o.cash(second), 1590);
    expect(o.cash(first), 1410);
  });

  test('nearest station; owned pays double rent', () {
    for (final id in [4, 5]) {
      expect(draw(7, id).position(first), 15);
      expect(draw(22, id).position(first), 25);
      final w = draw(36, id);
      expect((w.position(first), w.cash(first)), (5, 1700));
      final o = draw(7, id, owners: {15: second, 25: second});
      expect(o.cash(second), 1600, reason: 'two stations: 50, doubled');
    }
  });

  test('collect and pay cards', () {
    final cases = {6: 50, 15: 150, 11: -15, 17: 200, 18: -50, 19: 50, 22: 100, 23: 20, 25: 100, 26: -100, 27: -50, 28: 25, 30: 10, 31: 100};
    cases.forEach((id, delta) {
      final b = draw(id < 16 ? 7 : 17, id);
      expect(b.cash(first), 1500 + delta, reason: '$id');
      expect(b.events.last.kind, delta > 0 ? LandlordEventKind.collected : LandlordEventKind.paid, reason: '$id');
    });
  });

  test('get out of jail free is held, not returned', () {
    for (final (at, id) in [(7, 7), (17, 20)]) {
      final b = draw(at, id);
      expect(b.heldCards(first), [id]);
      expect(b.deck(LandlordCard.values[id].deck), hasLength(15));
      expect(b.deck(LandlordCard.values[id].deck), isNot(contains(id)));
    }
  });

  test('go back 3 spaces', () {
    var b = draw(7, 8);
    expect((b.position(first), b.cash(first)), (4, 1300));
    b = draw(22, 8);
    expect((b.position(first), b.phase), (19, LandlordPhase.buy));
    // From 36 back to 33, Family Fund: its top card (16, advance to Start).
    b = draw(36, 8);
    expect(b.position(first), 0);
    expect(b.cash(first), 1700);
    expect(b.events.where((e) => e.kind == LandlordEventKind.drew).map((e) => e.card), [LandlordCard.luckBack3, LandlordCard.fundToStart]);
  });

  test('go to jail', () {
    for (final (at, id) in [(7, 9), (17, 21)]) {
      final b = draw(at, id);
      expect((b.position(first), b.inJail(first), b.cash(first), b.phase), (10, true, 1500, LandlordPhase.end));
    }
  });

  test('repairs', () {
    final owners = {1: first, 3: first, 37: first, 39: first};
    final levels = {1: 2, 3: 3, 37: 5, 39: 4};
    expect(draw(7, 10, owners: owners, levels: levels).cash(first), 1500 - (9 * 25 + 100));
    expect(draw(17, 29, owners: owners, levels: levels).cash(first), 1500 - (9 * 40 + 115));
    expect(draw(7, 10).cash(first), 1500, reason: 'nothing built, nothing paid');
  });

  test('advance to South Station and Vista Heights', () {
    var b = draw(7, 12);
    expect((b.position(first), b.cash(first)), (5, 1700));
    b = draw(7, 13);
    expect((b.position(first), b.cash(first)), (39, 1500));
  });

  test('pay the other player 50; collect 10 from the other player', () {
    var b = draw(7, 14);
    expect((b.cash(first), b.cash(second)), (1450, 1550));
    b = draw(17, 24);
    expect((b.cash(first), b.cash(second)), (1510, 1490));
  });
}
