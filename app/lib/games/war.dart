import 'package:flutter/foundation.dart';

import 'rng.dart';
import 'rules.dart';

/// One battle in War, for the table and its log. [rounds] are the face-up
/// pairs as (first's card, second's card): one, plus one per war. [downs] is
/// how many cards each player laid face down before each war's flip (one
/// entry per war). [winner] took the [pot]; null when both decks ran out in
/// a war and each took back their own cards.
@immutable
class WarBattle {
  const WarBattle(this.flipper, this.rounds, this.downs, this.winner, this.pot);

  final Side flipper;
  final List<(int, int)> rounds;
  final List<int> downs;
  final Side? winner;
  final int pot;

  bool get war => rounds.length > 1;
}

/// Two-player War, one pass through the deck. Cards are `0..51` as in Go
/// Fish: rank = `card ~/ 4 + 1` (1 = ace … 13 = king), suit = `card % 4`;
/// aces are high. The deck is shuffled with the seed and dealt alternately,
/// 26 each, from the first player. Move: `{"flip": true}` by the player whose
/// turn it is, and turns alternate. A flip turns both decks' top cards: the
/// higher takes both. A tie is a war: each lays up to 3 cards face down
/// (keeping one to flip) and flips again, until someone wins; if both decks
/// run out first, each takes back their own cards. Won cards are kept, not
/// played again. When the decks are empty, more cards wins (reason `cards`);
/// equal is a draw.
class WarBoard implements Board {
  WarBoard._(
    List<int> firstDeck,
    List<int> secondDeck,
    this.won,
    List<WarBattle> battles,
    this._turn,
  ) : _decks = (List.unmodifiable(firstDeck), List.unmodifiable(secondDeck)),
      battles = List.unmodifiable(battles);

  factory WarBoard.deal(int seed) {
    final deck = shuffled(List.generate(52, (i) => i), Rng(seed));
    return WarBoard._(
      [for (var i = 0; i < 52; i += 2) deck[i]],
      [for (var i = 1; i < 52; i += 2) deck[i]],
      (0, 0),
      const [],
      Side.first,
    );
  }

  /// Decks as given (top first), nothing won yet.
  @visibleForTesting
  factory WarBoard.custom(
    List<int> firstDeck,
    List<int> secondDeck, {
    Side turn = Side.first,
  }) => WarBoard._(
    List.of(firstDeck),
    List.of(secondDeck),
    (0, 0),
    const [],
    turn,
  );

  static const maxBattles = 200;

  static int rankOf(int card) => card ~/ 4 + 1;
  static int suitOf(int card) => card % 4;

  /// A card's strength: 2..13, aces 14.
  static int valueOf(int card) => rankOf(card) == 1 ? 14 : rankOf(card);

  final (List<int>, List<int>) _decks;
  final Side _turn;

  /// Cards won as (first, second).
  final (int, int) won;

  /// The battles so far, oldest first; at most the last [maxBattles].
  final List<WarBattle> battles;

  /// [s]'s deck, top first.
  List<int> deck(Side s) => s == Side.first ? _decks.$1 : _decks.$2;

  bool get _over => _decks.$1.isEmpty || _decks.$2.isEmpty;

  @override
  Side get toMove => _turn;

  @override
  Outcome? get outcome {
    if (!_over) return null;
    final (a, b) = won;
    return Outcome(a == b ? null : (a > b ? Side.first : Side.second), 'cards');
  }

  @override
  bool get drawOffers => false;

  @override
  Board? play(Map<String, Object?> move) {
    if (move['flip'] != true || _over) return null;
    final a = List.of(_decks.$1), b = List.of(_decks.$2);
    final rounds = <(int, int)>[];
    final downs = <int>[];
    var pot = 0;
    Side? winner;
    while (true) {
      final x = a.removeAt(0), y = b.removeAt(0);
      pot += 2;
      rounds.add((x, y));
      if (valueOf(x) != valueOf(y)) {
        winner = valueOf(x) > valueOf(y) ? Side.first : Side.second;
        break;
      }
      // War: both decks are always the same size, so both lay the same.
      if (a.isEmpty) break;
      final n = a.length - 1 < 3 ? a.length - 1 : 3;
      a.removeRange(0, n);
      b.removeRange(0, n);
      pot += 2 * n;
      downs.add(n);
    }
    final (wa, wb) = won;
    final next = switch (winner) {
      Side.first => (wa + pot, wb),
      Side.second => (wa, wb + pot),
      null => (wa + pot ~/ 2, wb + pot ~/ 2),
    };
    final log = [...battles, WarBattle(_turn, rounds, downs, winner, pot)];
    return WarBoard._(
      a,
      b,
      next,
      log.length > maxBattles ? log.sublist(log.length - maxBattles) : log,
      _turn.other,
    );
  }
}
