import 'dart:math';

import 'package:famchat/games/landlord/landlord.dart';
import 'package:famchat/games/rng.dart';

/// The first seed from 1 up whose fresh [Rng] satisfies [ok].
int seedFor(bool Function(Rng r) ok) {
  for (var s = 1;; s++) {
    if (ok(Rng(s))) return s;
  }
}

(int, int) roll(Rng r) => (r.randInt(6) + 1, r.randInt(6) + 1);

/// A generator state whose next rolls are [rolls], in order.
int rollsSeed(List<(int, int)> rolls) => seedFor((r) => rolls.every((p) => roll(r) == p));

/// Plays action [a] with fields [f]; fails the test if it is illegal.
LandlordBoard act(LandlordBoard b, String a, [Map<String, Object?> f = const {}]) {
  final next = b.play({'a': a, ...f});
  if (next == null) throw StateError('illegal: $a $f in ${b.phase}');
  return next as LandlordBoard;
}

/// Whether action [a] with fields [f] is legal.
bool legal(LandlordBoard b, String a, [Map<String, Object?> f = const {}]) =>
    b.play({'a': a, ...f}) != null;

/// A random legal Landlord action for whoever must act (without `type`),
/// favouring the ones that move the game along. Null if none is legal.
Map<String, Object?>? randomLandlordAction(Random rnd, LandlordBoard b) {
  final me = b.toMove;
  final owned = [for (var s = 0; s < 40; s++) if (b.owner(s) == me) s];
  final theirs = [for (var s = 0; s < 40; s++) if (b.owner(s) == me.other) s];
  final progress = <Map<String, Object?>>[
    {'a': 'roll'}, {'a': 'buy'}, {'a': 'end_turn'}, {'a': 'accept'},
  ];
  final other = <Map<String, Object?>>[
    {'a': 'decline'}, {'a': 'pay_bail'}, {'a': 'use_card'}, {'a': 'reject'},
    for (final s in owned) ...[
      {'a': 'build', 'space': s}, {'a': 'sell', 'space': s},
      {'a': 'mortgage', 'space': s}, {'a': 'unmortgage', 'space': s},
    ],
    if (owned.isNotEmpty && theirs.isNotEmpty)
      {'a': 'offer', 'give': {'spaces': [owned[rnd.nextInt(owned.length)]]}, 'get': {'spaces': [theirs[rnd.nextInt(theirs.length)]], 'cash': 0}},
    if (owned.isNotEmpty) {'a': 'offer', 'give': {'spaces': [owned.first]}, 'get': {'cash': 50}},
  ];
  final legalProgress = progress.where((m) => b.play(m) != null).toList();
  final legalOther = other.where((m) => b.play(m) != null).toList();
  if (legalProgress.isEmpty && legalOther.isEmpty) return null;
  final pickOther = legalOther.isNotEmpty && (legalProgress.isEmpty || rnd.nextInt(4) == 0);
  final from = pickOther ? legalOther : legalProgress;
  return from[rnd.nextInt(from.length)];
}
