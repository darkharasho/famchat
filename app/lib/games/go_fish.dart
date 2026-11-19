import 'package:flutter/foundation.dart';

import 'rng.dart';
import 'rules.dart';

/// One ask in Go Fish, for the public log. [given] is how many cards the
/// opponent handed over; [drawn] the card drawn on "Go fish" (null after a
/// match or with an empty stock). The UI must not name [drawn] to the
/// opponent unless it matched ([again] without [given]). [booked] holds the
/// books this play laid, as (holder, rank).
@immutable
class GoFishEvent {
  const GoFishEvent(
    this.asker,
    this.rank,
    this.given,
    this.drawn,
    this.again,
    this.booked,
  );

  final Side asker;
  final int rank, given;
  final int? drawn;
  final bool again;
  final List<(Side, int)> booked;
}

/// Two-player Go Fish. Cards are `0..51`: rank = `card ~/ 4 + 1` (1 = ace …
/// 13 = king), suit = `card % 4` (♠ ♥ ♦ ♣). Move: `{"rank": 1..13}`, a rank
/// the mover holds. A match or a lucky draw goes again. Fours of a kind are
/// booked automatically; a player left with no cards draws one. The game ends
/// at 13 books: more books wins (reason `books`).
class GoFishBoard implements Board {
  GoFishBoard._(
    List<int> first,
    List<int> second,
    List<int> stock,
    List<int> firstBooks,
    List<int> secondBooks,
    List<GoFishEvent> events,
    this._turn,
  ) : _hands = (
        List.unmodifiable(first..sort()),
        List.unmodifiable(second..sort()),
      ),
      _stock = List.unmodifiable(stock),
      _books = (List.unmodifiable(firstBooks), List.unmodifiable(secondBooks)),
      events = List.unmodifiable(events);

  /// Shuffles `0..51` with [seed], deals 7 each alternating from the first
  /// player off the top (index 0), and books any dealt four of a kind.
  factory GoFishBoard.deal(int seed) {
    final deck = shuffled(List.generate(52, (i) => i), Rng(seed));
    final first = <int>[], second = <int>[];
    for (var i = 0; i < 2 * handSize; i++) {
      (i.isEven ? first : second).add(deck[i]);
    }
    final firstBooks = _layBooks(first), secondBooks = _layBooks(second);
    return GoFishBoard._(
      first,
      second,
      deck.sublist(2 * handSize),
      firstBooks,
      secondBooks,
      const [],
      Side.first,
    );
  }

  /// A position as given, with [turn] due (subject to the empty-hand pass).
  /// Lays no books.
  @visibleForTesting
  factory GoFishBoard.custom({
    required List<int> firstHand,
    required List<int> secondHand,
    required List<int> stock,
    List<int> firstBooks = const [],
    List<int> secondBooks = const [],
    Side turn = Side.first,
  }) => GoFishBoard._(
    List.of(firstHand),
    List.of(secondHand),
    List.of(stock),
    List.of(firstBooks),
    List.of(secondBooks),
    const [],
    turn,
  );

  static const handSize = 7;
  static const ranks = 13;

  /// How many events [events] keeps.
  static const maxEvents = 200;

  static int rankOf(int card) => card ~/ 4 + 1;
  static int suitOf(int card) => card % 4;

  final (List<int>, List<int>) _hands, _books;
  final List<int> _stock;
  final Side _turn;

  /// The asks so far, oldest first; at most the last [maxEvents].
  final List<GoFishEvent> events;

  /// [s]'s hand, sorted ascending.
  List<int> hand(Side s) => s == Side.first ? _hands.$1 : _hands.$2;

  /// [s]'s books, as ranks in the order made.
  List<int> books(Side s) => s == Side.first ? _books.$1 : _books.$2;

  int get stockCount => _stock.length;

  /// Books made as (first, second).
  (int, int) get scores => (_books.$1.length, _books.$2.length);

  bool get _over => _books.$1.length + _books.$2.length == ranks;

  @override
  Side get toMove =>
      hand(_turn).isEmpty && _stock.isEmpty ? _turn.other : _turn;

  @override
  Outcome? get outcome {
    if (!_over) return null;
    final (a, b) = scores;
    return Outcome(a > b ? Side.first : Side.second, 'books');
  }

  @override
  bool get drawOffers => false;

  @override
  Board? play(Map<String, Object?> move) {
    final rank = wireInt(move['rank']);
    if (rank == null || rank < 1 || rank > ranks || _over) return null;
    final me = toMove;
    final mine = List.of(hand(me)), theirs = List.of(hand(me.other));
    if (!mine.any((c) => rankOf(c) == rank)) return null;
    final stock = List.of(_stock);

    final given = theirs.where((c) => rankOf(c) == rank).toList();
    int? drawn;
    final bool again;
    if (given.isNotEmpty) {
      theirs.removeWhere((c) => rankOf(c) == rank);
      mine.addAll(given);
      again = true;
    } else if (stock.isNotEmpty) {
      drawn = stock.removeAt(0);
      mine.add(drawn);
      again = rankOf(drawn) == rank;
    } else {
      again = false;
    }

    final myBooks = List.of(books(me)), theirBooks = List.of(books(me.other));
    final booked = <(Side, int)>[];
    for (final r in _layBooks(mine)) {
      myBooks.add(r);
      booked.add((me, r));
    }
    for (final r in _layBooks(theirs)) {
      theirBooks.add(r);
      booked.add((me.other, r));
    }
    for (final h in [mine, theirs]) {
      if (h.isEmpty && stock.isNotEmpty) h.add(stock.removeAt(0));
    }

    final event = GoFishEvent(me, rank, given.length, drawn, again, booked);
    final log = [...events, event];
    final first = me == Side.first;
    return GoFishBoard._(
      first ? mine : theirs,
      first ? theirs : mine,
      stock,
      first ? myBooks : theirBooks,
      first ? theirBooks : myBooks,
      log.length > maxEvents ? log.sublist(log.length - maxEvents) : log,
      again ? me : me.other,
    );
  }

  /// Removes every four of a kind from [hand]; returns their ranks, lowest
  /// first.
  static List<int> _layBooks(List<int> hand) {
    final counts = List.filled(ranks + 1, 0);
    for (final c in hand) {
      counts[rankOf(c)]++;
    }
    final out = [for (var r = 1; r <= ranks; r++) if (counts[r] == 4) r];
    hand.removeWhere((c) => out.contains(rankOf(c)));
    return out;
  }
}
