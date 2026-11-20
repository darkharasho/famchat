import 'package:famchat/games/landlord/landlord.dart';
import 'package:famchat/games/rng.dart';
import 'package:famchat/games/rules.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

const first = Side.first, second = Side.second;

LandlordBoard at(int pos, List<(int, int)> rolls, {Map<int, Side> owners = const {}, Map<int, int> levels = const {}, Set<int> mortgaged = const {}, (int, int) cash = (1500, 1500)}) =>
    LandlordBoard.custom(
      rng: rollsSeed(rolls),
      positions: (pos, 0),
      owners: owners,
      levels: levels,
      mortgaged: mortgaged,
      cash: cash,
    );

void main() {
  test('setup', () {
    final b = LandlordBoard.setup(1);
    expect((b.position(first), b.position(second)), (0, 0));
    expect((b.cash(first), b.cash(second)), (1500, 1500));
    expect(b.phase, LandlordPhase.roll);
    expect(b.toMove, first);
    expect(b.turn, first);
    expect(b.drawOffers, isTrue);
    expect(b.outcome, isNull);
    expect(b.events, isEmpty);
    final r = Rng(1);
    final luck = shuffled(List.generate(16, (i) => i), r);
    final fund = shuffled(List.generate(16, (i) => i + 16), r);
    expect(b.deck(LandlordDeck.luck), luck);
    expect(b.deck(LandlordDeck.fund), fund);
    expect(b.housesLeft, 32);
    expect(b.hotelsLeft, 12);
  });

  test('roll and move', () {
    final b = act(at(0, [(2, 4)]), 'roll');
    expect(b.position(first), 6);
    expect(b.dice, (2, 4));
    expect(b.events.single.kind, LandlordEventKind.rolled);
    expect(b.events.single.space, 6);
    expect(b.events.single.dice, (2, 4));
    expect(b.phase, LandlordPhase.buy);
  });

  test('passing or landing on Start pays 200', () {
    final b = act(at(37, [(1, 3)]), 'roll');
    expect(b.position(first), 1);
    expect(b.cash(first), 1700);
    expect(b.events.map((e) => e.kind), contains(LandlordEventKind.passedStart));
    final land = act(at(36, [(1, 3)], owners: {}), 'roll');
    expect(land.position(first), 0);
    expect(land.cash(first), 1700);
  });

  test('passing Start onto a property', () {
    final b = act(at(35, [(2, 4)]), 'roll'); // → 1
    expect(b.position(first), 1);
    expect(b.cash(first), 1700);
    expect(b.phase, LandlordPhase.buy);
  });

  test('buy', () {
    final b = act(act(at(0, [(2, 4)]), 'roll'), 'buy');
    expect(b.owner(6), first);
    expect(b.cash(first), 1400);
    expect(b.phase, LandlordPhase.end);
    expect(b.events.last.kind, LandlordEventKind.bought);
    final poor = act(at(0, [(2, 4)], cash: (99, 1500)), 'roll');
    expect(legal(poor, 'buy'), isFalse);
    expect(legal(poor, 'decline'), isTrue);
  });

  test('doubles roll again', () {
    final b = act(act(at(0, [(3, 3)]), 'roll'), 'buy');
    expect(b.phase, LandlordPhase.roll);
    expect(b.turn, first);
  });

  test('third doubles in a row goes to jail', () {
    var b = at(10, [(1, 1), (2, 2), (3, 3)], owners: {12: first, 16: first});
    b = act(b, 'roll');
    expect((b.position(first), b.phase), (12, LandlordPhase.roll));
    b = act(b, 'roll');
    expect((b.position(first), b.phase), (16, LandlordPhase.roll));
    b = act(b, 'roll');
    expect(b.position(first), 10);
    expect(b.inJail(first), isTrue);
    expect(b.phase, LandlordPhase.end);
    expect(b.events.last.kind, LandlordEventKind.jailed);
  });

  test('rent on colours', () {
    var b = act(at(38, [(1, 2)], owners: {1: second}), 'roll');
    expect(b.cash(first), 1500 + 200 - 2);
    expect(b.cash(second), 1502);
    expect(b.events.last.kind, LandlordEventKind.rent);
    expect(b.events.last.amount, 2);
    expect(b.events.last.other, second);

    b = act(at(38, [(1, 2)], owners: {1: second, 3: second}), 'roll');
    expect(b.cash(second), 1504, reason: 'full set doubles');

    b = act(at(38, [(1, 2)], owners: {1: second, 3: second}, levels: {1: 3, 3: 3}), 'roll');
    expect(b.cash(second), 1590);

    b = act(at(38, [(1, 2)], owners: {1: second}, mortgaged: {1}), 'roll');
    expect(b.cash(second), 1500, reason: 'mortgaged charges nothing');
    expect(b.phase, LandlordPhase.end);
  });

  test('a mortgaged sibling still doubles unimproved rent', () {
    final b = act(at(38, [(1, 2)], owners: {1: second, 3: second}, mortgaged: {3}), 'roll');
    expect(b.cash(second), 1504);
  });

  test('station rent counts stations owned, mortgaged ones too', () {
    for (final (owned, rent) in [([5], 25), ([5, 15], 50), ([5, 15, 25], 100), ([5, 15, 25, 35], 200)]) {
      final b = act(at(0, [(2, 3)], owners: {for (final s in owned) s: second}, mortgaged: owned.length > 1 ? {owned.last} : {}), 'roll');
      expect(b.cash(second), 1500 + rent, reason: '$owned');
      expect(b.rentFor(5), rent);
    }
  });

  test('utility rent: 4x or 10x the dice', () {
    var b = act(at(7, [(2, 3)], owners: {12: second}), 'roll');
    expect(b.cash(second), 1500 + 20);
    b = act(at(7, [(2, 3)], owners: {12: second, 28: second}), 'roll');
    expect(b.cash(second), 1500 + 50);
    expect(b.rentFor(12, diceTotal: 7), 70);
  });

  test('tax', () {
    var b = act(at(0, [(1, 3)]), 'roll');
    expect(b.cash(first), 1300);
    expect(b.events.last.kind, LandlordEventKind.tax);
    b = act(at(35, [(1, 2)]), 'roll');
    expect(b.cash(first), 1400);
  });

  test('tax goes into the Rest Stop pot', () {
    var b = act(at(0, [(1, 3)]), 'roll');
    expect(b.pot, 200);
    b = act(at(35, [(1, 2)]), 'roll');
    expect(b.pot, 100);
  });

  test('landing on Rest Stop collects the pot', () {
    var b = LandlordBoard.custom(rng: rollsSeed([(4, 6)]), positions: (10, 0), pot: 300);
    b = act(b, 'roll');
    expect((b.position(first), b.cash(first), b.pot), (20, 1800, 0));
    expect(b.events.last.kind, LandlordEventKind.pot);
    expect(b.events.last.amount, 300);
  });

  test('an empty pot pays nothing', () {
    final b = act(at(10, [(4, 6)]), 'roll');
    expect((b.cash(first), b.pot), (1500, 0));
    expect(b.events.last.kind, LandlordEventKind.rolled);
  });

  test('tax owed goes into the pot once it is paid', () {
    var b = act(at(0, [(1, 3)], owners: {1: first}, cash: (180, 1500)), 'roll');
    expect((b.phase, b.pot), (LandlordPhase.debt, 0));
    b = act(b, 'mortgage', {'space': 1});
    expect((b.phase, b.cash(first), b.pot), (LandlordPhase.end, 180 + 30 - 200, 200));
  });

  test('Go to Jail space', () {
    var b = act(at(25, [(2, 3)]), 'roll');
    expect((b.position(first), b.inJail(first), b.phase), (10, true, LandlordPhase.end));
    expect(b.cash(first), 1500);
    b = act(at(26, [(2, 2)]), 'roll');
    expect((b.position(first), b.phase), (10, LandlordPhase.end), reason: 'no extra roll from jail');
  });

  test('in jail: doubles leave and move, no extra roll', () {
    final b = act(LandlordBoard.custom(rng: rollsSeed([(2, 2)]), positions: (10, 0), jailed: first), 'roll');
    expect(b.inJail(first), isFalse);
    expect(b.position(first), 14);
    expect(b.phase, LandlordPhase.buy);
    expect(act(b, 'decline').phase, LandlordPhase.end);
  });

  test('in jail: failed rolls stay; the third pays 50 and moves', () {
    var b = LandlordBoard.custom(rng: rollsSeed([(1, 2), (1, 2), (1, 2)]), positions: (10, 0), jailed: first);
    b = act(b, 'roll');
    expect((b.inJail(first), b.jailTries, b.position(first), b.phase), (true, 1, 10, LandlordPhase.end));
    b = LandlordBoard.custom(rng: rollsSeed([(1, 2)]), positions: (10, 0), jailed: first, jailTries: 1);
    b = act(b, 'roll');
    expect((b.inJail(first), b.jailTries, b.position(first)), (true, 2, 10));
    b = LandlordBoard.custom(rng: rollsSeed([(1, 2)]), positions: (10, 0), jailed: first, jailTries: 2);
    b = act(b, 'roll');
    expect(b.inJail(first), isFalse);
    expect(b.cash(first), 1450);
    expect(b.position(first), 13);
    expect(b.pot, 50);
    expect(b.phase, LandlordPhase.buy);
  });

  test('pay bail', () {
    final j = LandlordBoard.custom(positions: (10, 0), jailed: first);
    final b = act(j, 'pay_bail');
    expect((b.inJail(first), b.cash(first), b.phase), (false, 1450, LandlordPhase.roll));
    expect(b.pot, 50);
    expect(legal(LandlordBoard.custom(), 'pay_bail'), isFalse);
    expect(legal(LandlordBoard.custom(positions: (10, 0), jailed: first, cash: (49, 1500)), 'pay_bail'), isFalse);
  });

  test('use a jail-free card', () {
    final j = LandlordBoard.custom(positions: (10, 0), jailed: first, held: ([7], []));
    expect(j.deck(LandlordDeck.luck), hasLength(15));
    final b = act(j, 'use_card');
    expect(b.inJail(first), isFalse);
    expect(b.heldCards(first), isEmpty);
    expect(b.deck(LandlordDeck.luck).last, 7);
    expect(b.phase, LandlordPhase.roll);
    expect(legal(LandlordBoard.custom(positions: (10, 0), jailed: first), 'use_card'), isFalse);
  });

  test('end turn', () {
    final b = act(act(at(0, [(2, 4)]), 'roll'), 'buy');
    final n = act(b, 'end_turn');
    expect((n.turn, n.toMove, n.phase), (second, second, LandlordPhase.roll));
    expect(legal(n, 'end_turn'), isFalse);
  });

  test('illegal input', () {
    final b = LandlordBoard.custom();
    for (final m in <Map<String, Object?>>[{'a': 'fly'}, {'a': 7}, {}, {'a': 'buy'}, {'a': 'end_turn'}]) {
      expect(b.play(m), isNull, reason: '$m');
    }
  });
}
