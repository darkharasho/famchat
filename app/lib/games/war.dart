import 'package:flutter/foundation.dart';

import 'rng.dart';
import 'rules.dart';

/// One battle in War, for the table and its log. [rounds] are the face-up
/// pairs as (first's card, second's card): one, plus one per war. [downs] is
/// how many cards each player laid face down before each war's flip (one
/// entry per war). [winner] took the [pot]; null when both decks ran out in
/// a war and each took back their own cards. [laid] is every card each
/// player put down, (first's, second's), in the order laid: the table shows
/// them all when a war is won.
@immutable
class WarBattle {
  const WarBattle(this.flipper, this.rounds, this.downs, this.winner, this.pot, [this.laid = const ([], [])]);

  final (List<int>, List<int>) laid;

  final Side flipper;
  final List<(int, int)> rounds;
  final List<int> downs;
  final Side? winner;
  final int pot;

  bool get war => rounds.length > 1;
}

/// Two-player War. Cards are `0..51` as in Go Fish: rank = `card ~/ 4 + 1`
/// (1 = ace … 13 = king), suit = `card % 4`; aces are high. The deck is
/// shuffled with the seed and dealt alternately, 26 each, from the first
/// player. Move: `{"flip": true}` by the player whose turn it is, and turns
/// alternate. A flip turns both decks' top cards: the higher takes both. A tie
/// is a war: each lays up to 3 cards face down (keeping one to flip) and flips
/// again, until someone wins; if both run out first, each takes back their own
/// cards. Won cards go on the winner's pile, in the order they were laid,
/// first's before second's.
///
/// By default ([wholeDeck] false) the decks are played once: won cards are
/// kept, and when the decks are empty more cards wins (reason `cards`); equal
/// is a draw. With [wholeDeck], a player whose deck is empty when they need a
/// card shuffles their pile into it (the generator carrying on from the deal),
/// and the game ends when one player has every card (reason `cards`). A war
/// lays `min(3, fewer cards held - 1)` each; a player with no card to flip
/// loses the battle.
///
/// With [twosBeatAces] (a house rule) a 2 beats an ace; every other card still
/// loses to the ace, and the 2 still loses to everything else.
class WarBoard implements Board {
  WarBoard._(
    List<int> firstDeck,
    List<int> secondDeck,
    List<int> firstPile,
    List<int> secondPile,
    List<WarBattle> battles,
    this._turn,
    this._rng, {
    required this.wholeDeck,
    required this.twosBeatAces,
    required this.flips,
  }) : _decks = (List.unmodifiable(firstDeck), List.unmodifiable(secondDeck)),
       _piles = (List.unmodifiable(firstPile), List.unmodifiable(secondPile)),
       battles = List.unmodifiable(battles);

  factory WarBoard.deal(int seed, {bool wholeDeck = false, bool twosBeatAces = false}) {
    final rng = Rng(seed);
    final deck = shuffled(List.generate(52, (i) => i), rng);
    return WarBoard._(
      [for (var i = 0; i < 52; i += 2) deck[i]],
      [for (var i = 1; i < 52; i += 2) deck[i]],
      const [],
      const [],
      const [],
      Side.first,
      rng.state,
      wholeDeck: wholeDeck,
      twosBeatAces: twosBeatAces,
      flips: 0,
    );
  }

  /// Decks and piles as given (top first).
  @visibleForTesting
  factory WarBoard.custom(
    List<int> firstDeck,
    List<int> secondDeck, {
    Side turn = Side.first,
    bool wholeDeck = false,
    bool twosBeatAces = false,
    List<int> firstPile = const [],
    List<int> secondPile = const [],
    int seed = 1,
  }) => WarBoard._(
    firstDeck,
    secondDeck,
    firstPile,
    secondPile,
    const [],
    turn,
    Rng(seed).state,
    wholeDeck: wholeDeck,
    twosBeatAces: twosBeatAces,
    flips: 0,
  );

  static const maxBattles = 200;

  static int rankOf(int card) => card ~/ 4 + 1;
  static int suitOf(int card) => card % 4;

  /// A card's strength: 2..13, aces 14.
  static int valueOf(int card) => rankOf(card) == 1 ? 14 : rankOf(card);

  final (List<int>, List<int>) _decks, _piles;
  final Side _turn;

  /// The generator's state, for the next reshuffle.
  final int _rng;

  /// Play until one player has every card, reshuffling won cards.
  final bool wholeDeck;

  /// House rule: a 2 beats an ace.
  final bool twosBeatAces;

  /// Whether card [x] beats card [y] (cards of equal value are a war).
  bool beats(int x, int y) {
    final a = valueOf(x), b = valueOf(y);
    if (twosBeatAces && a == 2 && b == 14) return true;
    if (twosBeatAces && a == 14 && b == 2) return false;
    return a > b;
  }

  /// Battles played.
  final int flips;

  /// The battles so far, oldest first; at most the last [maxBattles].
  final List<WarBattle> battles;

  /// [s]'s deck, top first.
  List<int> deck(Side s) => s == Side.first ? _decks.$1 : _decks.$2;

  /// [s]'s won cards, in the order won.
  List<int> pile(Side s) => s == Side.first ? _piles.$1 : _piles.$2;

  /// Cards won as (first, second): the piles' sizes.
  (int, int) get won => (_piles.$1.length, _piles.$2.length);

  /// Cards held, deck and pile, as (first, second).
  (int, int) get held => (
    _decks.$1.length + _piles.$1.length,
    _decks.$2.length + _piles.$2.length,
  );

  /// The score: cards won, or with [wholeDeck] cards held.
  (int, int) get score => wholeDeck ? held : won;

  bool get _over => wholeDeck
      ? held.$1 == 0 || held.$2 == 0
      : _decks.$1.isEmpty || _decks.$2.isEmpty;

  @override
  Side get toMove => _turn;

  @override
  Outcome? get outcome {
    if (!_over) return null;
    final (a, b) = score;
    return Outcome(a == b ? null : (a > b ? Side.first : Side.second), 'cards');
  }

  @override
  bool get drawOffers => false;

  @override
  Board? play(Map<String, Object?> move) {
    if (move['flip'] != true || _over) return null;
    final decks = [List.of(_decks.$1), List.of(_decks.$2)];
    final piles = [List.of(_piles.$1), List.of(_piles.$2)];
    final rng = Rng(_rng);
    // Cards laid this battle, by side, in order.
    final laid = [<int>[], <int>[]];
    int? take(int s) {
      if (decks[s].isEmpty && wholeDeck && piles[s].isNotEmpty) {
        decks[s] = shuffled(piles[s], rng);
        piles[s] = [];
      }
      if (decks[s].isEmpty) return null;
      final c = decks[s].removeAt(0);
      laid[s].add(c);
      return c;
    }

    int heldBy(int s) => decks[s].length + piles[s].length;
    final rounds = <(int, int)>[];
    final downs = <int>[];
    Side? winner;
    while (true) {
      final x = take(0), y = take(1);
      if (x == null || y == null) {
        // Only with wholeDeck: whoever can't flip loses the war.
        if (x != null || y != null) {
          winner = x == null ? Side.second : Side.first;
        }
        break;
      }
      rounds.add((x, y));
      if (valueOf(x) != valueOf(y)) {
        winner = beats(x, y) ? Side.first : Side.second;
        break;
      }
      final fewer = wholeDeck
          ? (heldBy(0) < heldBy(1) ? heldBy(0) : heldBy(1))
          : decks[0].length; // Both decks are the same size.
      if (fewer == 0) {
        if (!wholeDeck || heldBy(0) == heldBy(1)) break;
        continue; // The player with none loses on the next flip.
      }
      final n = fewer - 1 < 3 ? fewer - 1 : 3;
      for (var k = 0; k < n; k++) {
        take(0);
        take(1);
      }
      downs.add(n);
    }
    final pot = laid[0].length + laid[1].length;
    switch (winner) {
      case Side.first:
        piles[0].addAll([...laid[0], ...laid[1]]);
      case Side.second:
        piles[1].addAll([...laid[0], ...laid[1]]);
      case null:
        piles[0].addAll(laid[0]);
        piles[1].addAll(laid[1]);
    }
    final log = [
      ...battles,
      WarBattle(_turn, rounds, downs, winner, pot, (List.unmodifiable(laid[0]), List.unmodifiable(laid[1]))),
    ];
    return WarBoard._(
      decks[0],
      decks[1],
      piles[0],
      piles[1],
      log.length > maxBattles ? log.sublist(log.length - maxBattles) : log,
      _turn.other,
      rng.state,
      wholeDeck: wholeDeck,
      twosBeatAces: twosBeatAces,
      flips: flips + 1,
    );
  }
}
