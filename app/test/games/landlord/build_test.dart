import 'package:famchat/games/landlord/landlord.dart';
import 'package:famchat/games/rules.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

const first = Side.first, second = Side.second;

LandlordBoard mine(Map<int, int> levels, {Set<int> mortgaged = const {}, List<int> extra = const [], (int, int) cash = (1500, 1500), Map<int, Side> theirs = const {}}) =>
    LandlordBoard.custom(
      owners: {for (final s in [...levels.keys, ...extra]) s: first, ...theirs},
      levels: {for (final e in levels.entries) if (e.value > 0) e.key: e.value},
      mortgaged: mortgaged,
      cash: cash,
    );

Map<String, Object?> at(int s) => {'space': s};

/// Levels that put [n] houses on the board (on spaces first can't touch).
Map<int, int> housesUsed(int n) {
  final out = <int, int>{};
  for (final s in [6, 8, 9, 11, 13, 14, 16, 18, 19, 21, 23, 24]) {
    if (n <= 0) break;
    final k = n >= 4 ? 4 : n;
    out[s] = k;
    n -= k;
  }
  return out;
}

void main() {
  test('build needs a full, unmortgaged colour set', () {
    expect(legal(LandlordBoard.custom(owners: {1: first}), 'build', at(1)), isFalse);
    final b = act(mine({1: 0, 3: 0}), 'build', at(1));
    expect((b.level(1), b.cash(first)), (1, 1450));
    expect(b.events.last.kind, LandlordEventKind.built);
    expect(legal(mine({1: 0, 3: 0}, mortgaged: {3}), 'build', at(1)), isFalse);
    expect(legal(mine({5: 0, 15: 0, 25: 0, 35: 0}), 'build', at(5)), isFalse);
    expect(legal(mine({12: 0, 28: 0}), 'build', at(12)), isFalse);
    expect(legal(mine({1: 0, 3: 0}, cash: (49, 1500)), 'build', at(1)), isFalse);
    for (final bad in [-1, 40, '1', null, 1.5]) {
      expect(legal(mine({1: 0, 3: 0}), 'build', {'space': bad}), isFalse);
    }
  });

  test('build evenly', () {
    final b = mine({1: 1, 3: 0});
    expect(legal(b, 'build', at(1)), isFalse);
    expect(legal(b, 'build', at(3)), isTrue);
  });

  test('a hotel replaces 4 houses and returns them', () {
    final b = mine({37: 4, 39: 4});
    final h = act(b, 'build', at(39));
    expect(h.level(39), 5);
    expect(legal(mine({37: 4, 39: 3}), 'build', at(37)), isFalse);
  });

  test('the bank never runs out of houses or hotels', () {
    final houses = LandlordBoard.custom(
      owners: {1: first, 3: first, for (final s in housesUsed(32).keys) s: second},
      levels: housesUsed(32),
    );
    expect(legal(houses, 'build', at(1)), isTrue);
    final hotels = {6: 5, 8: 5, 9: 5, 11: 5, 13: 5, 14: 5, 16: 5, 18: 5, 19: 5, 21: 5, 23: 5, 24: 5};
    final full = LandlordBoard.custom(
      owners: {37: first, 39: first, for (final s in hotels.keys) s: second},
      levels: {37: 4, 39: 4, ...hotels},
    );
    expect(act(full, 'build', at(37)).level(37), 5);
  });

  test('build only in roll or end, by the turn player', () {
    final b = LandlordBoard.custom(rng: rollsSeed([(2, 4)]), owners: {1: first, 3: first});
    final buying = act(b, 'roll');
    expect(buying.phase, LandlordPhase.buy);
    expect(legal(buying, 'build', at(1)), isFalse);
    final ended = act(buying, 'buy');
    expect(ended.phase, LandlordPhase.end);
    expect(legal(ended, 'build', at(1)), isTrue);
  });

  test('sell is the reverse of building', () {
    final b = mine({1: 2, 3: 1});
    expect(legal(b, 'sell', at(3)), isFalse, reason: 'sell evenly');
    final s = act(b, 'sell', at(1));
    expect((s.level(1), s.cash(first)), (1, 1525));
    expect(s.events.last.kind, LandlordEventKind.sold);
    expect(legal(mine({1: 0, 3: 0}), 'sell', at(1)), isFalse);
    final h = act(mine({37: 5, 39: 5}), 'sell', at(39));
    expect((h.level(39), h.cash(first)), (4, 1600));
  });

  test('mortgage', () {
    final b = act(LandlordBoard.custom(owners: {1: first}), 'mortgage', at(1));
    expect((b.isMortgaged(1), b.cash(first)), (true, 1530));
    expect(b.events.last.kind, LandlordEventKind.mortgaged);
    expect(legal(b, 'mortgage', at(1)), isFalse);
    expect(legal(mine({1: 0, 3: 1}), 'mortgage', at(1)), isFalse, reason: 'buildings in the set');
    expect(legal(LandlordBoard.custom(owners: {1: second}), 'mortgage', at(1)), isFalse);
    expect(legal(LandlordBoard.custom(), 'mortgage', at(1)), isFalse);
    expect(act(LandlordBoard.custom(owners: {5: first}), 'mortgage', at(5)).cash(first), 1600);
  });

  test('unmortgage costs the mortgage value plus 10%, rounded up', () {
    for (final (sp, cost) in [(1, 33), (39, 220), (11, 77), (12, 83)]) {
      final b = act(LandlordBoard.custom(owners: {sp: first}, mortgaged: {sp}), 'unmortgage', at(sp));
      expect((b.isMortgaged(sp), b.cash(first)), (false, 1500 - cost), reason: '$sp');
      expect(legal(LandlordBoard.custom(owners: {sp: first}, mortgaged: {sp}, cash: (cost - 1, 1500)), 'unmortgage', at(sp)), isFalse);
    }
    expect(legal(LandlordBoard.custom(owners: {1: first}), 'unmortgage', at(1)), isFalse);
  });

  test('liquidation counts cash, buildings and mortgage values', () {
    final b = LandlordBoard.custom(
      owners: {37: first, 39: first, 1: first, 5: first},
      levels: {37: 5, 39: 4},
      mortgaged: {5},
      cash: (10, 1500),
    );
    expect(b.liquidation(first), 10 + 9 * 100 + 175 + 200 + 30);
  });
}
