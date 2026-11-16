import 'dart:math';

const _alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
final _random = Random.secure();

int _lastMs = -1;
List<int> _lastRand = const [];

/// A ULID: 10 chars of millisecond time + 16 random chars (Crockford base32), as the server makes.
/// Monotonic within this process: ids made in the same millisecond (or after the clock steps
/// back) increment the previous random part, so sorting ids sorts by creation order.
String newUlid([DateTime? now]) {
  var ms = (now ?? DateTime.now()).millisecondsSinceEpoch;
  List<int> rand;
  if (ms <= _lastMs) {
    ms = _lastMs;
    rand = [..._lastRand];
    for (var i = rand.length - 1; i >= 0; i--) {
      if (rand[i] < 31) {
        rand[i]++;
        break;
      }
      rand[i] = 0;
    }
  } else {
    rand = List.generate(16, (_) => _random.nextInt(32));
  }
  _lastMs = ms;
  _lastRand = rand;
  final time = List.filled(10, '0');
  var t = ms;
  for (var i = 9; i >= 0; i--) {
    time[i] = _alphabet[t % 32];
    t ~/= 32;
  }
  return time.join() + rand.map((r) => _alphabet[r]).join();
}
