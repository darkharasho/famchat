import 'dart:math';

const _alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
final _random = Random.secure();

/// A ULID: 10 chars of millisecond time + 16 random chars (Crockford base32), as the server makes.
String newUlid([DateTime? now]) {
  var t = (now ?? DateTime.now()).millisecondsSinceEpoch;
  final time = List.filled(10, '0');
  for (var i = 9; i >= 0; i--) {
    time[i] = _alphabet[t % 32];
    t ~/= 32;
  }
  final rand = List.generate(16, (_) => _alphabet[_random.nextInt(32)]);
  return time.join() + rand.join();
}
