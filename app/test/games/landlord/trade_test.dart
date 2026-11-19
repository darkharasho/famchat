import 'package:famchat/games/landlord/landlord.dart';
import 'package:famchat/games/rules.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

const first = Side.first, second = Side.second;

/// First lands on unowned Cedar Street (#6) and declines it.
LandlordBoard declined({(int, int) roll = (2, 4), Map<int, Side> owners = const {}, (int, int) cash = (1500, 1500)}) =>
    act(act(LandlordBoard.custom(rng: rollsSeed([roll]), owners: owners, cash: cash), 'roll'), 'decline');

Map<String, Object?> offer({int giveCash = 0, List<int> giveSpaces = const [], int giveCards = 0, int getCash = 0, List<int> getSpaces = const [], int getCards = 0}) => {
  'give': {'cash': giveCash, 'spaces': giveSpaces, 'cards': giveCards},
  'get': {'cash': getCash, 'spaces': getSpaces, 'cards': getCards},
};

void main() {
  test('declining leaves the property with the bank; no auction', () {
    final b = declined();
    expect(b.owner(6), isNull);
    expect(b.cash(first), 1500);
    expect((b.phase, b.toMove), (LandlordPhase.end, first));
    expect(b.events.last.kind, LandlordEventKind.declined);
    for (final a in ['bid', 'pass']) {
      expect(legal(b, a, {'amount': 10}), isFalse, reason: a);
    }
  });

  test('declining after doubles returns to roll', () {
    final b = declined(roll: (3, 3));
    expect((b.phase, b.turn), (LandlordPhase.roll, first));
  });

  test('offer validation', () {
    final b = LandlordBoard.custom(owners: {1: first, 6: second, 3: second}, levels: {}, held: ([7], []));
    expect(legal(b, 'offer', offer(giveSpaces: [1], getSpaces: [6])), isTrue);
    expect(legal(b, 'offer', offer(giveCards: 1, getCash: 20)), isTrue);
    expect(legal(b, 'offer', offer()), isFalse, reason: 'nothing on either side');
    expect(legal(b, 'offer', offer(giveSpaces: [6])), isFalse, reason: "not mine");
    expect(legal(b, 'offer', offer(getSpaces: [1])), isFalse, reason: 'not theirs');
    expect(legal(b, 'offer', offer(giveSpaces: [9])), isFalse, reason: 'unowned');
    expect(legal(b, 'offer', offer(giveSpaces: [1, 1])), isFalse, reason: 'twice');
    expect(legal(b, 'offer', offer(giveCash: 1501)), isFalse);
    expect(legal(b, 'offer', offer(getCash: 1501)), isFalse);
    expect(legal(b, 'offer', offer(giveCards: 2)), isFalse);
    expect(legal(b, 'offer', offer(getCards: 1)), isFalse);
    expect(legal(b, 'offer', offer(giveCash: -5, getSpaces: [6])), isFalse);
    expect(legal(b, 'offer', {'give': 'x', 'get': {}}), isFalse);
    expect(legal(b, 'offer', {'give': {'spaces': [1, 'x']}, 'get': {}}), isFalse);
    final built = LandlordBoard.custom(owners: {1: first, 3: first, 6: second}, levels: {3: 1});
    expect(legal(built, 'offer', offer(giveSpaces: [1], getSpaces: [6])), isFalse, reason: 'set has buildings');
    final o = act(b, 'offer', offer(giveSpaces: [1], getSpaces: [6]));
    expect((o.phase, o.toMove), (LandlordPhase.trade, second));
    expect(o.events.last.kind, LandlordEventKind.offered);
    expect(legal(o, 'offer', offer(giveCash: 1)), isFalse);
  });

  test('offers only from the turn player in roll or end', () {
    final b = act(LandlordBoard.custom(rng: rollsSeed([(2, 4)]), owners: {1: first}), 'roll');
    expect(b.phase, LandlordPhase.buy);
    expect(legal(b, 'offer', offer(giveSpaces: [1])), isFalse);
    expect(legal(act(b, 'buy'), 'offer', offer(giveSpaces: [1])), isTrue);
  });

  test('accept swaps; mortgaged property costs its receiver interest', () {
    final b = LandlordBoard.custom(owners: {1: first, 39: second}, mortgaged: {39}, held: ([7], []));
    final o = act(b, 'offer', offer(giveSpaces: [1], giveCash: 100, giveCards: 1, getSpaces: [39]));
    final a = act(o, 'accept');
    expect((a.owner(1), a.owner(39)), (second, first));
    expect(a.isMortgaged(39), isTrue);
    expect(a.cash(first), 1500 - 100 - 20);
    expect(a.cash(second), 1600);
    expect(a.heldCards(first), isEmpty);
    expect(a.heldCards(second), [7]);
    expect(a.phase, LandlordPhase.roll);
    expect(a.toMove, first);
    expect(a.events.map((e) => e.kind), containsAllInOrder([LandlordEventKind.accepted, LandlordEventKind.interest]));
  });

  test('reject changes nothing', () {
    final b = LandlordBoard.custom(owners: {1: first, 6: second});
    final r = act(act(b, 'offer', offer(giveSpaces: [1], getSpaces: [6])), 'reject');
    expect((r.owner(1), r.owner(6), r.phase, r.toMove), (first, second, LandlordPhase.roll, first));
    expect(r.events.last.kind, LandlordEventKind.rejected);
  });

  test('during a trade only accept or reject', () {
    final b = LandlordBoard.custom(owners: {1: first, 6: second, 9: second});
    final o = act(b, 'offer', offer(giveSpaces: [1], getSpaces: [6]));
    for (final a in ['roll', 'end_turn']) {
      expect(legal(o, a), isFalse, reason: a);
    }
    expect(legal(o, 'mortgage', {'space': 9}), isFalse);
    expect(legal(o, 'sell', {'space': 9}), isFalse);
  });
}
