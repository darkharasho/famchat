import 'dart:math';

/// The shared random generator for games with luck (docs/protocol.md
/// "Games"): xorshift32 seeded from the `game` message's `seed`.
///
/// Permanent wire format: changing it changes every past game. It uses only
/// shifts, xor and 32-bit masks, never multiplication, so the web (32-bit
/// bitwise) and the VM (64-bit ints) produce the same values.
class Rng {
  /// State = [seed], or `0x9E3779B9` when it is 0 (xorshift never leaves 0).
  Rng(int seed) : _x = seed == 0 ? 0x9E3779B9 : seed & _mask;

  static const _mask = 0xFFFFFFFF;

  int _x;

  /// The current state: the last [next] value, or the starting state.
  int get state => _x;

  /// The next unsigned 32-bit value.
  int next() {
    var x = _x;
    x ^= (x << 13) & _mask;
    x ^= x >> 17;
    x ^= (x << 5) & _mask;
    return _x = x;
  }

  /// A value in `0..n-1` (`next() % n`; the small bias is accepted).
  int randInt(int n) => next() % n;
}

/// A copy of [items] shuffled by Fisher–Yates from the end: for `i` from
/// `len-1` down to 1, swap `i` with `rng.randInt(i + 1)`.
List<T> shuffled<T>(List<T> items, Rng rng) {
  final out = List.of(items);
  for (var i = out.length - 1; i > 0; i--) {
    final j = rng.randInt(i + 1);
    final t = out[i];
    out[i] = out[j];
    out[j] = t;
  }
  return out;
}

/// A fresh seed for a new game: secure random, `0..4294967295`. The bound
/// is a literal: on the web `1 << 32` is 0.
int newSeed() => Random.secure().nextInt(0x100000000);
