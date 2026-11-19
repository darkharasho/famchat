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
