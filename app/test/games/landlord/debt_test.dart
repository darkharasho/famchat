import 'package:famchat/games/landlord/landlord.dart';
import 'package:famchat/games/rules.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

const first = Side.first, second = Side.second;

/// First draws Family Fund card 24 ("collect 10 from the other player") at #17.
LandlordBoard birthday({required (int, int) cash, Map<int, Side> owners = const {}}) => act(
  LandlordBoard.custom(
    rng: rollsSeed([(1, 2)]),
    positions: (14, 0),
    cash: cash,
    owners: owners,
    fund: [24, for (var i = 16; i < 32; i++) if (i != 24) i],
  ),
  'roll',
);

void main() {
  test('rent you cannot pay: debt, then paid by mortgaging', () {
    final b = act(LandlordBoard.custom(rng: rollsSeed([(1, 2)]), positions: (36, 0), cash: (100, 1500), owners: {39: second, 1: first, 3: first, 6: first}, levels: {39: 1}), 'roll');
    expect(b.phase, LandlordPhase.debt);
    expect(b.toMove, first);
    expect(b.debts.single.amount, 200);
    expect(b.debts.single.creditor, second);
    expect(b.events.last.kind, LandlordEventKind.owes);
    expect(b.events.last.space, 39);
    expect(b.events.where((e) => e.kind == LandlordEventKind.rent), isEmpty, reason: 'not paid yet');
    for (final a in ['roll', 'end_turn', 'buy']) {
      expect(legal(b, a), isFalse, reason: a);
    }
    expect(legal(b, 'build', {'space': 1}), isFalse);
    expect(legal(b, 'offer', {'give': {'spaces': [1]}}), isFalse);
    var p = act(b, 'mortgage', {'space': 1});
    expect(p.phase, LandlordPhase.debt);
    p = act(p, 'mortgage', {'space': 6});
    expect(p.phase, LandlordPhase.debt, reason: '100+30+50 < 200');
    p = act(p, 'mortgage', {'space': 3});
    expect(p.debts, isEmpty);
    expect((p.cash(first), p.cash(second)), (10, 1700));
    expect(p.events.last.kind, LandlordEventKind.debtPaid);
    expect(p.phase, LandlordPhase.end);
    expect(p.toMove, first);
  });

  test('a debt out of turn: the other player owes, then play resumes', () {
    final b = birthday(cash: (1500, 5), owners: {6: second});
    expect(b.phase, LandlordPhase.debt);
    expect(b.toMove, second);
    expect(b.events.where((e) => e.kind == LandlordEventKind.collected), isEmpty, reason: 'not paid yet');
    expect((b.events.last.kind, b.events.last.actor, b.events.last.other), (LandlordEventKind.owes, second, first));
    final p = act(b, 'mortgage', {'space': 6});
    expect((p.cash(first), p.cash(second)), (1510, 45));
    expect(p.toMove, first);
    expect(p.phase, LandlordPhase.end);
  });

  test('third failed jail roll without bail money: debt, then the move', () {
    final b = act(
      LandlordBoard.custom(rng: rollsSeed([(1, 2)]), positions: (10, 0), jailed: first, jailTries: 2, cash: (20, 1500), owners: {1: first}),
      'roll',
    );
    expect(b.phase, LandlordPhase.debt);
    expect(b.position(first), 10);
    final p = act(b, 'mortgage', {'space': 1});
    expect((b.pot, p.cash(first), p.pot), (0, 0, 50));
    expect(p.position(first), 13);
    expect(p.phase, LandlordPhase.buy);
    expect(p.inJail(first), isFalse);
  });

  test('mortgage interest on a trade can be a debt', () {
    final b = LandlordBoard.custom(owners: {39: first, 6: second, 8: second}, mortgaged: {39}, cash: (1500, 0));
    final o = act(b, 'offer', {'give': {'spaces': [39]}, 'get': {'spaces': [6]}});
    final a = act(o, 'accept');
    expect(a.phase, LandlordPhase.debt);
    expect(a.toMove, second);
    final p = act(a, 'mortgage', {'space': 8});
    expect(p.cash(second), 30);
    expect((p.phase, p.toMove), (LandlordPhase.roll, first));
  });

  test('automatic bankruptcy when nothing can cover the debt', () {
    final b = birthday(cash: (1500, 0));
    expect(b.outcome?.winner, first);
    expect(b.outcome?.reason, 'bankrupt');
    expect(b.events.last.kind, LandlordEventKind.bankrupt);
    expect(b.events.last.actor, second);
    expect(b.play({'a': 'end_turn'}), isNull);
  });

  test('declaring bankruptcy', () {
    final b = birthday(cash: (1500, 5), owners: {6: second});
    final d = act(b, 'bankrupt');
    expect(d.outcome?.winner, first);
    expect(d.outcome?.reason, 'bankrupt');
    expect(legal(LandlordBoard.custom(), 'bankrupt'), isFalse);
  });

  test('events keep only the last 200', () {
    var b = LandlordBoard.custom(cash: (100000, 100000));
    for (var i = 0; i < 400; i++) {
      final a = switch (b.phase) {
        LandlordPhase.roll => 'roll',
        LandlordPhase.buy => 'decline',
        LandlordPhase.end => 'end_turn',
        final p => throw StateError('$p'),
      };
      final before = b.events.length;
      b = act(b, a);
      expect(b.events.length, lessThanOrEqualTo(LandlordBoard.maxEvents));
      if (before < LandlordBoard.maxEvents) expect(b.events.length, greaterThan(before));
    }
    expect(b.events, hasLength(200));
  });

  test('play never mutates the board', () {
    final b = LandlordBoard.custom(rng: rollsSeed([(2, 4)]));
    act(act(b, 'roll'), 'buy');
    expect((b.position(first), b.cash(first), b.owner(6), b.events.length, b.phase), (0, 1500, null, 0, LandlordPhase.roll));
  });
}
