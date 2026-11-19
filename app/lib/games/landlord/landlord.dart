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

  /// [s]'s cash plus everything they could sell or mortgage.
  int liquidation(Side s) => _state().liquidation(s);

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
      case 'build':
        final sp = _space(m);
        if (sp == null || !_turnActs || !(stage == _Stage.roll || stage == _Stage.end)) return false;
        return _build(me, sp);
      case 'unmortgage':
        final sp = _space(m);
        if (sp == null || !_turnActs || !(stage == _Stage.roll || stage == _Stage.end)) return false;
        if (owner[sp] != me || !mortgaged[sp]) return false;
        final mv = landlordSpaces[sp].mortgageValue;
        final cost = mv + (mv + 9) ~/ 10;
        if (cash[_i(me)] < cost) return false;
        cash[_i(me)] -= cost;
        mortgaged[sp] = false;
        log(LandlordEvent(me, LandlordEventKind.unmortgaged, space: sp, amount: cost));
      case 'sell':
        final sp = _space(m);
        if (sp == null || trade != null) return false;
        return _sell(toMove, sp);
      case 'mortgage':
        final sp = _space(m);
        if (sp == null || trade != null) return false;
        final who = toMove;
        final space = landlordSpaces[sp];
        if (owner[sp] != who || mortgaged[sp]) return false;
        if (groupSpaces(space.group!).any((g) => level[g] > 0)) return false;
        mortgaged[sp] = true;
        cash[_i(who)] += space.mortgageValue;
        log(LandlordEvent(who, LandlordEventKind.mortgaged, space: sp, amount: space.mortgageValue));
      case 'bid':
        final au = auction;
        final amount = wireInt(m['amount']);
        if (au == null || debts.isNotEmpty || amount == null) return false;
        final who = au.toBid;
        if (amount <= au.high || amount > cash[_i(who)]) return false;
        auction = LandlordAuction(au.space, amount, who, who.other, au.noBidPass);
        log(LandlordEvent(who, LandlordEventKind.bid, space: au.space, amount: amount));
      case 'pass':
        final au = auction;
        if (au == null || debts.isNotEmpty) return false;
        final who = au.toBid;
        log(LandlordEvent(who, LandlordEventKind.passed, space: au.space));
        final high = au.highBidder;
        if (high != null) {
          auction = null;
          cash[_i(high)] -= au.high;
          owner[au.space] = high;
          log(LandlordEvent(high, LandlordEventKind.auctionWon, space: au.space, amount: au.high));
        } else if (au.noBidPass) {
          auction = null;
          log(LandlordEvent(who, LandlordEventKind.auctionUnsold, space: au.space));
        } else {
          auction = LandlordAuction(au.space, 0, null, who.other, true);
        }
      case 'offer':
        if (!_turnActs || !(stage == _Stage.roll || stage == _Stage.end)) return false;
        final o = _parseOffer(me, m);
        if (o == null) return false;
        trade = o;
        log(LandlordEvent(me, LandlordEventKind.offered));
      case 'accept':
        final o = trade;
        if (o == null || debts.isNotEmpty) return false;
        _exchange(o);
      case 'reject':
        final o = trade;
        if (o == null || debts.isNotEmpty) return false;
        trade = null;
        log(LandlordEvent(o.from.other, LandlordEventKind.rejected));
      default:
        return false;
    }
    return true;
  }

  /// A valid offer from [me] in [m], or null.
  LandlordOffer? _parseOffer(Side me, Map<String, Object?> m) {
    (int, List<int>, int)? part(Object? v, Side giver) {
      if (v == null) return (0, const [], 0);
      if (v is! Map) return null;
      final c = v['cash'] == null ? 0 : wireInt(v['cash']);
      final k = v['cards'] == null ? 0 : wireInt(v['cards']);
      final raw = v['spaces'] ?? const [];
      if (c == null || k == null || c < 0 || k < 0 || raw is! List) return null;
      final spaces = <int>[];
      for (final x in raw) {
        final sp = wireInt(x);
        if (sp == null || sp < 0 || sp >= 40 || spaces.contains(sp)) return null;
        if (owner[sp] != giver) return null;
        final g = landlordSpaces[sp].group!;
        if (groupSpaces(g).any((y) => level[y] > 0)) return null;
        spaces.add(sp);
      }
      if (c > cash[_i(giver)] || k > held[_i(giver)].length) return null;
      return (c, spaces, k);
    }

    final give = part(m['give'], me), get = part(m['get'], me.other);
    if (give == null || get == null) return null;
    final empty = give.$1 == 0 && give.$2.isEmpty && give.$3 == 0 && get.$1 == 0 && get.$2.isEmpty && get.$3 == 0;
    if (empty) return null;
    return LandlordOffer(
      from: me,
      giveCash: give.$1,
      giveSpaces: List.unmodifiable(give.$2),
      giveCards: give.$3,
      getCash: get.$1,
      getSpaces: List.unmodifiable(get.$2),
      getCards: get.$3,
    );
  }

  /// Carries out an accepted offer, then charges mortgage interest: the
  /// offerer's first.
  void _exchange(LandlordOffer o) {
    final a = o.from, b = o.from.other;
    trade = null;
    cash[_i(a)] += o.getCash - o.giveCash;
    cash[_i(b)] += o.giveCash - o.getCash;
    for (final sp in o.giveSpaces) {
      owner[sp] = b;
    }
    for (final sp in o.getSpaces) {
      owner[sp] = a;
    }
    final aCards = held[_i(a)].sublist(0, o.giveCards);
    final bCards = held[_i(b)].sublist(0, o.getCards);
    held[_i(a)]
      ..removeRange(0, o.giveCards)
      ..addAll(bCards);
    held[_i(b)]
      ..removeRange(0, o.getCards)
      ..addAll(aCards);
    log(LandlordEvent(b, LandlordEventKind.accepted, other: a));
    for (final (to, spaces) in [(a, o.getSpaces), (b, o.giveSpaces)]) {
      for (final sp in spaces) {
        if (!mortgaged[sp]) continue;
        final mv = landlordSpaces[sp].mortgageValue;
        _charge(to, null, (mv + 9) ~/ 10, LandlordEventKind.interest, space: sp);
      }
    }
  }

  /// The `space` field, if it is a valid space index.
  static int? _space(Map<String, Object?> m) {
    final v = wireInt(m['space']);
    return v == null || v < 0 || v >= 40 ? null : v;
  }

  bool _build(Side me, int sp) {
    final space = landlordSpaces[sp];
    final g = space.group;
    if (g == null || !g.buildable || owner[sp] != me) return false;
    final set = groupSpaces(g);
    if (set.any((x) => owner[x] != me || mortgaged[x])) return false;
    final l = level[sp];
    if (l >= 5 || set.any((x) => level[x] < l)) return false;
    if (cash[_i(me)] < space.houseCost) return false;
    if (l == 4 ? hotelsLeft < 1 : housesLeft < 1) return false;
    cash[_i(me)] -= space.houseCost;
    level[sp] = l + 1;
    log(LandlordEvent(me, LandlordEventKind.built, space: sp, amount: space.houseCost));
    return true;
  }

  bool _sell(Side who, int sp) {
    final space = landlordSpaces[sp];
    final l = level[sp];
    if (owner[sp] != who || l == 0) return false;
    final half = space.houseCost ~/ 2;
    if (l == 5) {
      // Break the hotel down to 4 houses, or as many as the bank has,
      // selling the rest too (no even-selling check in that case).
      final keep = housesLeft < 4 ? housesLeft : 4;
      level[sp] = keep;
      final got = half * (1 + 4 - keep);
      cash[_i(who)] += got;
      log(LandlordEvent(who, LandlordEventKind.sold, space: sp, amount: got));
      return true;
    }
    if (groupSpaces(space.group!).any((x) => level[x] > l)) return false;
    level[sp] = l - 1;
    cash[_i(who)] += half;
    log(LandlordEvent(who, LandlordEventKind.sold, space: sp, amount: half));
    return true;
  }

  /// [s]'s cash plus everything they could sell or mortgage.
  int liquidation(Side s) {
    var total = cash[_i(s)];
    for (var sp = 0; sp < 40; sp++) {
      if (owner[sp] != s) continue;
      final space = landlordSpaces[sp];
      total += level[sp] * (space.houseCost ~/ 2);
      if (!mortgaged[sp]) total += space.mortgageValue;
    }
    return total;
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
    _applyCard(s, card);
  }

  void _applyCard(Side s, LandlordCard c) {
    void collect(int n) {
      cash[_i(s)] += n;
      log(LandlordEvent(s, LandlordEventKind.collected, amount: n));
    }

    void pay(int n) => _charge(s, null, n, LandlordEventKind.paid);

    int next(List<int> targets) {
      final at = pos[_i(s)];
      return targets.firstWhere((t) => t > at, orElse: () => targets.first);
    }

    int repairs(int house, int hotel) {
      var total = 0;
      for (var sp = 0; sp < 40; sp++) {
        if (owner[sp] != s) continue;
        final l = level[sp];
        total += l == 5 ? hotel : l * house;
      }
      return total;
    }

    switch (c) {
      case LandlordCard.luckToStart || LandlordCard.fundToStart:
        _moveTo(s, 0);
      case LandlordCard.luckToNettle:
        _moveTo(s, 24);
      case LandlordCard.luckToFern:
        _moveTo(s, 11);
      case LandlordCard.luckToNorthStation:
        _moveTo(s, 5);
      case LandlordCard.luckToVista:
        _moveTo(s, 39);
      case LandlordCard.luckToUtility:
        _moveTo(s, next(groupSpaces(LandlordGroup.utility)), utilityRoll: true);
      case LandlordCard.luckToStationA || LandlordCard.luckToStationB:
        _moveTo(s, next(groupSpaces(LandlordGroup.station)), rentFactor: 2);
      case LandlordCard.luckBack3:
        pos[_i(s)] = (pos[_i(s)] + 37) % 40;
        _resolve(s);
      case LandlordCard.luckToJail || LandlordCard.fundToJail:
        _goToJail(s);
      case LandlordCard.luckRepairs:
        pay(repairs(25, 100));
      case LandlordCard.fundRepairs:
        pay(repairs(40, 115));
      case LandlordCard.luckPayOther50:
        _charge(s, s.other, 50, LandlordEventKind.paid);
      case LandlordCard.fundFromOther:
        log(LandlordEvent(s, LandlordEventKind.collected, amount: 10, other: s.other));
        _charge(s.other, s, 10, null);
      case LandlordCard.luckCollect50 || LandlordCard.fundCollect50:
        collect(50);
      case LandlordCard.luckCollect150:
        collect(150);
      case LandlordCard.fundCollect200:
        collect(200);
      case LandlordCard.fundCollect100a || LandlordCard.fundCollect100b || LandlordCard.fundCollect100c:
        collect(100);
      case LandlordCard.fundCollect20:
        collect(20);
      case LandlordCard.fundCollect25:
        collect(25);
      case LandlordCard.fundCollect10:
        collect(10);
      case LandlordCard.luckPay15:
        pay(15);
      case LandlordCard.fundPay50 || LandlordCard.fundPay50b:
        pay(50);
      case LandlordCard.fundPay100:
        pay(100);
      case LandlordCard.luckJailFree || LandlordCard.fundJailFree:
        break; // Held above.
    }
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
  /// [kind] null logs nothing (the caller already did).
  void _charge(Side from, Side? to, int amount, LandlordEventKind? kind, {int? space}) {
    if (amount <= 0) return;
    debts.add(LandlordDebt(from, to, amount));
    if (kind != null) log(LandlordEvent(from, kind, amount: amount, space: space, other: to));
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
