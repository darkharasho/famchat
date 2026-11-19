import 'package:flutter/foundation.dart';

import '../rng.dart';
import '../rules.dart';
import 'cards.dart';
import 'events.dart';
import 'spaces.dart';

export 'cards.dart';
export 'events.dart';
export 'spaces.dart';

/// What the player who must act now is doing.
enum LandlordPhase { roll, buy, end, auction, trade, debt }

/// The turn player's own stage. [jailMove] is the third failed jail roll
/// waiting for its bail debt to be paid; it is never a visible phase.
enum _Stage { roll, buy, end, jailMove }

/// A running auction for [space]. [high] 0 means no bid yet.
@immutable
class LandlordAuction {
  const LandlordAuction(this.space, this.high, this.highBidder, this.toBid, this.noBidPass);

  final int space, high;
  final Side? highBidder;
  final Side toBid;

  /// Whether one player has already passed with no bid standing.
  final bool noBidPass;
}

/// A pending trade offer from [from] to the other player.
@immutable
class LandlordOffer {
  const LandlordOffer({
    required this.from,
    this.giveCash = 0,
    this.giveCards = 0,
    this.getCash = 0,
    this.getCards = 0,
    this.giveSpaces = const [],
    this.getSpaces = const [],
  });

  final Side from;
  final int giveCash, giveCards, getCash, getCards;
  final List<int> giveSpaces, getSpaces;
}

/// [debtor] owes [amount] to [creditor] (null: the bank).
@immutable
class LandlordDebt {
  const LandlordDebt(this.debtor, this.creditor, this.amount);

  final Side debtor;
  final Side? creditor;
  final int amount;
}

int _i(Side s) => s == Side.first ? 0 : 1;

/// Two-player Landlord, a full-rules property-trading game
/// (docs/superpowers/specs/2026-11-18-go-fish-and-landlord-design.md).
/// Moves are `{"a": "<action>", ...}`; [toMove] is whoever must act now.
class LandlordBoard implements Board {
  LandlordBoard._(_State s)
    : _rng = s.rng,
      turn = s.turn,
      _pos = List.unmodifiable(s.pos),
      _cash = List.unmodifiable(s.cash),
      _owner = List.unmodifiable(s.owner),
      _level = List.unmodifiable(s.level),
      _mortgaged = List.unmodifiable(s.mortgaged),
      _inJail = List.unmodifiable(s.inJail),
      _tries = List.unmodifiable(s.tries),
      _held = List.unmodifiable([for (final h in s.held) List<int>.unmodifiable(h)]),
      _luck = List.unmodifiable(s.luck),
      _fund = List.unmodifiable(s.fund),
      _stage = s.stage,
      _again = s.again,
      _doubles = s.doubles,
      dice = s.dice,
      auction = s.auction,
      trade = s.trade,
      debts = List.unmodifiable(s.debts),
      events = List.unmodifiable(s.events),
      _outcome = s.outcome;

  /// A new game: shuffles Luck, then Family Fund, with [seed].
  factory LandlordBoard.setup(int seed) {
    final r = Rng(seed);
    final luck = shuffled(List.generate(16, (i) => i), r);
    final fund = shuffled(List.generate(16, (i) => i + 16), r);
    return LandlordBoard._(_State.fresh(r.state, luck, fund));
  }

  /// A position as given, for tests. Null decks are in their pre-shuffle
  /// order without the [held] cards.
  @visibleForTesting
  factory LandlordBoard.custom({
    int rng = 1,
    Side turn = Side.first,
    (int, int) positions = (0, 0),
    (int, int) cash = (startCash, startCash),
    Map<int, Side> owners = const {},
    Map<int, int> levels = const {},
    Set<int> mortgaged = const {},
    Side? jailed,
    int jailTries = 0,
    (List<int>, List<int>) held = (const [], const []),
    List<int>? luck,
    List<int>? fund,
  }) {
    final allHeld = {...held.$1, ...held.$2};
    final s = _State.fresh(
      rng,
      luck ?? [for (var i = 0; i < 16; i++) if (!allHeld.contains(i)) i],
      fund ?? [for (var i = 16; i < 32; i++) if (!allHeld.contains(i)) i],
    )
      ..turn = turn
      ..pos = [positions.$1, positions.$2]
      ..cash = [cash.$1, cash.$2]
      ..held = [List.of(held.$1), List.of(held.$2)];
    owners.forEach((k, v) => s.owner[k] = v);
    levels.forEach((k, v) => s.level[k] = v);
    for (final m in mortgaged) {
      s.mortgaged[m] = true;
    }
    if (jailed != null) {
      s.inJail[_i(jailed)] = true;
      s.tries[_i(jailed)] = jailTries;
    }
    return LandlordBoard._(s);
  }

  static const startCash = 1500, salary = 200, bail = 50, maxEvents = 200;
  static const houses = 32, hotels = 12;

  final int _rng;

  /// Whose turn it is (not necessarily [toMove]).
  final Side turn;
  final List<int> _pos, _cash, _level, _tries;
  final List<Side?> _owner;
  final List<bool> _mortgaged, _inJail;
  final List<List<int>> _held;
  final List<int> _luck, _fund;
  final _Stage _stage;
  final bool _again;
  final int _doubles;
  final Outcome? _outcome;

  /// The last roll, or null before the first.
  final (int, int)? dice;
  final LandlordAuction? auction;
  final LandlordOffer? trade;

  /// Debts still to pay, oldest first.
  final List<LandlordDebt> debts;

  /// Recent events, oldest first; at most [maxEvents].
  final List<LandlordEvent> events;

  int position(Side s) => _pos[_i(s)];
  int cash(Side s) => _cash[_i(s)];
  Side? owner(int space) => _owner[space];
  int level(int space) => _level[space];
  bool isMortgaged(int space) => _mortgaged[space];
  bool inJail(Side s) => _inJail[_i(s)];

  /// The turn player's failed jail rolls so far.
  int get jailTries => _tries[_i(turn)];
  List<int> heldCards(Side s) => _held[_i(s)];

  @visibleForTesting
  List<int> deck(LandlordDeck d) => d == LandlordDeck.luck ? _luck : _fund;

  int get housesLeft => _state().housesLeft;
  int get hotelsLeft => _state().hotelsLeft;

  LandlordPhase get phase {
    if (debts.isNotEmpty) return LandlordPhase.debt;
    if (auction != null) return LandlordPhase.auction;
    if (trade != null) return LandlordPhase.trade;
    return switch (_stage) {
      _Stage.roll || _Stage.jailMove => LandlordPhase.roll,
      _Stage.buy => LandlordPhase.buy,
      _Stage.end => LandlordPhase.end,
    };
  }

  /// The rent a visitor would pay on [space] now (0 if unowned or
  /// mortgaged). Utilities need [diceTotal].
  int rentFor(int space, {int? diceTotal}) => _state().rentFor(space, diceTotal ?? 0);

  @override
  Side get toMove => _state().toMove;

  @override
  Outcome? get outcome => _outcome;

  @override
  bool get drawOffers => true;

  @override
  Board? play(Map<String, Object?> move) {
    if (_outcome != null) return null;
    final a = move['a'];
    if (a is! String) return null;
    final s = _state();
    if (!s.act(a, move)) return null;
    s.settle();
    if (s.events.length > maxEvents) {
      s.events.removeRange(0, s.events.length - maxEvents);
    }
    return LandlordBoard._(s);
  }

  _State _state() => _State(
    rng: _rng,
    turn: turn,
    pos: List.of(_pos),
    cash: List.of(_cash),
    owner: List.of(_owner),
    level: List.of(_level),
    mortgaged: List.of(_mortgaged),
    inJail: List.of(_inJail),
    tries: List.of(_tries),
    held: [for (final h in _held) List.of(h)],
    luck: List.of(_luck),
    fund: List.of(_fund),
    stage: _stage,
    again: _again,
    doubles: _doubles,
    dice: dice,
    auction: auction,
    trade: trade,
    debts: List.of(debts),
    events: List.of(events),
    outcome: _outcome,
  );
}

/// The mutable working copy one [LandlordBoard.play] edits.
class _State {
  _State({
    required this.rng,
    required this.turn,
    required this.pos,
    required this.cash,
    required this.owner,
    required this.level,
    required this.mortgaged,
    required this.inJail,
    required this.tries,
    required this.held,
    required this.luck,
    required this.fund,
    required this.stage,
    required this.again,
    required this.doubles,
    required this.dice,
    required this.auction,
    required this.trade,
    required this.debts,
    required this.events,
    required this.outcome,
  });

  factory _State.fresh(int rng, List<int> luck, List<int> fund) => _State(
    rng: rng,
    turn: Side.first,
    pos: [0, 0],
    cash: [LandlordBoard.startCash, LandlordBoard.startCash],
    owner: List.filled(40, null),
    level: List.filled(40, 0),
    mortgaged: List.filled(40, false),
    inJail: [false, false],
    tries: [0, 0],
    held: [[], []],
    luck: luck,
    fund: fund,
    stage: _Stage.roll,
    again: false,
    doubles: 0,
    dice: null,
    auction: null,
    trade: null,
    debts: [],
    events: [],
    outcome: null,
  );

  int rng;
  Side turn;
  List<int> pos, cash, level, tries;
  List<Side?> owner;
  List<bool> mortgaged, inJail;
  List<List<int>> held;
  List<int> luck, fund;
  _Stage stage;
  bool again;
  int doubles;
  (int, int)? dice;
  LandlordAuction? auction;
  LandlordOffer? trade;
  List<LandlordDebt> debts;
  List<LandlordEvent> events;
  Outcome? outcome;

  int get housesLeft =>
      LandlordBoard.houses - level.where((l) => l >= 1 && l <= 4).fold(0, (a, l) => a + l);
  int get hotelsLeft => LandlordBoard.hotels - level.where((l) => l == 5).length;

  Side get toMove {
    if (debts.isNotEmpty) return debts.first.debtor;
    final au = auction;
    if (au != null) return au.toBid;
    final t = trade;
    if (t != null) return t.from.other;
    return turn;
  }

  bool get _turnActs => debts.isEmpty && auction == null && trade == null;

  void log(LandlordEvent e) => events.add(e);

  (int, int) _roll() {
    final r = Rng(rng);
    final d = (r.randInt(6) + 1, r.randInt(6) + 1);
    rng = r.state;
    return d;
  }

  // ---- Actions ----

  /// Applies action [a]; false if it is illegal now.
  bool act(String a, Map<String, Object?> m) {
    final me = turn;
    switch (a) {
      case 'roll':
        if (!_turnActs || stage != _Stage.roll) return false;
        _doRoll();
      case 'pay_bail':
        if (!_turnActs || stage != _Stage.roll || !inJail[_i(me)]) return false;
        if (cash[_i(me)] < LandlordBoard.bail) return false;
        cash[_i(me)] -= LandlordBoard.bail;
        _leaveJail(me);
        log(LandlordEvent(me, LandlordEventKind.bail, amount: LandlordBoard.bail));
      case 'use_card':
        if (!_turnActs || stage != _Stage.roll || !inJail[_i(me)]) return false;
        if (held[_i(me)].isEmpty) return false;
        final card = held[_i(me)].removeAt(0);
        _deckOf(LandlordCard.values[card].deck).add(card);
        _leaveJail(me);
        log(LandlordEvent(me, LandlordEventKind.usedCard, card: LandlordCard.values[card]));
      case 'buy':
        if (!_turnActs || stage != _Stage.buy) return false;
        final sp = pos[_i(me)];
        final price = landlordSpaces[sp].price;
        if (cash[_i(me)] < price) return false;
        cash[_i(me)] -= price;
        owner[sp] = me;
        log(LandlordEvent(me, LandlordEventKind.bought, space: sp, amount: price));
        _continue();
      case 'decline':
        if (!_turnActs || stage != _Stage.buy) return false;
        final sp = pos[_i(me)];
        log(LandlordEvent(me, LandlordEventKind.declined, space: sp));
        auction = LandlordAuction(sp, 0, null, me, false);
        _continue();
      case 'end_turn':
        if (!_turnActs || stage != _Stage.end) return false;
        log(LandlordEvent(me, LandlordEventKind.endTurn));
        turn = me.other;
        stage = _Stage.roll;
        again = false;
        doubles = 0;
      default:
        return false;
    }
    return true;
  }

  /// After a landing, buy or auction: roll again on doubles, else end.
  void _continue() => stage = again ? _Stage.roll : _Stage.end;

  void _leaveJail(Side s) {
    inJail[_i(s)] = false;
    tries[_i(s)] = 0;
  }

  void _goToJail(Side s) {
    pos[_i(s)] = 10;
    inJail[_i(s)] = true;
    tries[_i(s)] = 0;
    again = false;
    doubles = 0;
    stage = _Stage.end;
    log(LandlordEvent(s, LandlordEventKind.jailed));
  }

  void _doRoll() {
    final me = turn;
    final d = _roll();
    dice = d;
    final isDouble = d.$1 == d.$2;
    final total = d.$1 + d.$2;
    if (inJail[_i(me)]) {
      if (isDouble) {
        _leaveJail(me);
        log(LandlordEvent(me, LandlordEventKind.leftJail, dice: d));
        again = false;
        _moveBy(me, total);
        return;
      }
      tries[_i(me)]++;
      if (tries[_i(me)] < 3) {
        log(LandlordEvent(me, LandlordEventKind.rolled, dice: d, space: 10));
        again = false;
        stage = _Stage.end;
        return;
      }
      // Third failed roll: pay bail (maybe as a debt), then move.
      log(LandlordEvent(me, LandlordEventKind.rolled, dice: d, space: 10));
      _leaveJail(me);
      again = false;
      stage = _Stage.jailMove;
      _charge(me, null, LandlordBoard.bail, LandlordEventKind.bail);
      return;
    }
    if (isDouble) {
      doubles++;
      if (doubles == 3) {
        log(LandlordEvent(me, LandlordEventKind.rolled, dice: d, space: pos[_i(me)]));
        _goToJail(me);
        return;
      }
    }
    again = isDouble;
    _moveBy(me, total, rolled: d);
  }

  /// Moves [s] forward [n] spaces, collecting on passing Start, and resolves.
  void _moveBy(Side s, int n, {(int, int)? rolled}) {
    final from = pos[_i(s)];
    final to = (from + n) % 40;
    if (rolled != null) log(LandlordEvent(s, LandlordEventKind.rolled, dice: rolled, space: to));
    _moveTo(s, to);
  }

  /// Moves [s] clockwise to [to], collecting 200 on passing or landing on
  /// Start, and resolves the space.
  void _moveTo(Side s, int to, {int rentFactor = 1, bool utilityRoll = false}) {
    final from = pos[_i(s)];
    if (to < from || (to == 0 && from != 0)) {
      cash[_i(s)] += LandlordBoard.salary;
      log(LandlordEvent(s, LandlordEventKind.passedStart, amount: LandlordBoard.salary));
    }
    pos[_i(s)] = to;
    _resolve(s, rentFactor: rentFactor, utilityRoll: utilityRoll);
  }

  /// Applies the space [s] is on. Sets the next stage before charging, so a
  /// payment is always the last step.
  void _resolve(Side s, {int rentFactor = 1, bool utilityRoll = false}) {
    final sp = landlordSpaces[pos[_i(s)]];
    switch (sp.kind) {
      case SpaceKind.property || SpaceKind.station || SpaceKind.utility:
        final o = owner[sp.index];
        if (o == null) {
          stage = _Stage.buy;
          return;
        }
        _continue();
        if (o == s || mortgaged[sp.index]) return;
        int rent;
        if (utilityRoll) {
          final d = _roll();
          rent = 10 * (d.$1 + d.$2);
        } else {
          final d = dice;
          rent = rentFor(sp.index, d == null ? 0 : d.$1 + d.$2) * rentFactor;
        }
        _charge(s, o, rent, LandlordEventKind.rent, space: sp.index);
      case SpaceKind.tax:
        _continue();
        _charge(s, null, sp.tax, LandlordEventKind.tax, space: sp.index);
      case SpaceKind.card:
        _continue();
        _drawCard(s, sp.deck!);
      case SpaceKind.goToJail:
        _goToJail(s);
      case SpaceKind.start || SpaceKind.jail || SpaceKind.rest:
        _continue();
    }
  }

  List<int> _deckOf(LandlordDeck d) => d == LandlordDeck.luck ? luck : fund;

  /// Draws the top card of [d] for [s] and applies it.
  void _drawCard(Side s, LandlordDeck d) {
    final deck = _deckOf(d);
    final id = deck.removeAt(0);
    final card = LandlordCard.values[id];
    log(LandlordEvent(s, LandlordEventKind.drew, card: card));
    if (card.jailFree) {
      held[_i(s)].add(id);
      return;
    }
    deck.add(id);
  }

  int rentFor(int space, int diceTotal) {
    final o = owner[space];
    if (o == null || mortgaged[space]) return 0;
    final sp = landlordSpaces[space];
    final group = groupSpaces(sp.group!);
    final owned = group.where((g) => owner[g] == o).length;
    switch (sp.kind) {
      case SpaceKind.station:
        return 25 << (owned - 1);
      case SpaceKind.utility:
        return (owned == 2 ? 10 : 4) * diceTotal;
      default:
        final l = level[space];
        if (l > 0) return sp.rent[l];
        return owned == group.length ? sp.rent[0] * 2 : sp.rent[0];
    }
  }

  /// [from] pays [amount] to [to] (null: the bank) now, or owes it.
  void _charge(Side from, Side? to, int amount, LandlordEventKind kind, {int? space}) {
    if (amount <= 0) return;
    debts.add(LandlordDebt(from, to, amount));
    log(LandlordEvent(from, kind, amount: amount, space: space, other: to));
  }

  /// Pays what can be paid, then runs a waiting jail move.
  void settle() {
    while (outcome == null) {
      if (debts.isNotEmpty) {
        final d = debts.first;
        if (cash[_i(d.debtor)] < d.amount) return;
        debts.removeAt(0);
        cash[_i(d.debtor)] -= d.amount;
        final c = d.creditor;
        if (c != null) cash[_i(c)] += d.amount;
        continue;
      }
      if (stage == _Stage.jailMove) {
        stage = _Stage.end;
        final d = dice!;
        _moveBy(turn, d.$1 + d.$2);
        continue;
      }
      return;
    }
  }
}
