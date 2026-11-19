// Runs on the VM and in CI with `--platform chrome`: both must give the same
// values, since every phone replays shuffles and dice from the same seed.
import 'package:famchat/games/rng.dart';
import 'package:flutter_test/flutter_test.dart';

List<int> ten(int seed) {
  final r = Rng(seed);
  return [for (var i = 0; i < 10; i++) r.next()];
}

void main() {
  test('golden outputs', () {
    expect(ten(1), [
      270369, 67634689, 2647435461, 307599695, 2398689233, //
      745495504, 632435482, 435756210, 2005365029, 2916098932,
    ]);
    expect(ten(0), [
      1359758873, 3761132862, 2075758394, 25405621, 3862129951, //
      4186559031, 3122997712, 4244368831, 2831543865, 3042595768,
    ]);
    expect(ten(3735928559), [
      1199382711, 2384302402, 3129746520, 4276113467, 1745748808, //
      2760751131, 1649732188, 486387635, 2289630710, 1862841525,
    ]);
  });

  test('golden shuffle of 0..51 with seed 1', () {
    final deck = List.generate(52, (i) => i);
    expect(shuffled(deck, Rng(1)), [
      36, 48, 43, 18, 47, 3, 25, 29, 0, 34, 27, 5, 51, 12, 9, 45, 30, 40, //
      46, 13, 42, 38, 1, 31, 16, 33, 37, 6, 24, 7, 32, 50, 28, 49, 14, 4, //
      26, 35, 23, 2, 8, 44, 10, 41, 15, 20, 22, 17, 39, 11, 19, 21,
    ]);
    expect(deck, List.generate(52, (i) => i), reason: 'input untouched');
  });

  test('randInt stays in range and outputs are unsigned 32-bit', () {
    final r = Rng(42);
    for (var i = 0; i < 1000; i++) {
      final n = r.randInt(7);
      expect(n, inInclusiveRange(0, 6));
      final x = r.next();
      expect(x, inInclusiveRange(0, 0xFFFFFFFF));
      expect(r.state, x);
    }
  });

  test('newSeed picks a full-range 32-bit seed (web too)', () {
    final seeds = {for (var i = 0; i < 200; i++) newSeed()};
    for (final s in seeds) {
      expect(s, inInclusiveRange(0, 0xFFFFFFFF));
    }
    expect(seeds.length, greaterThan(190));
    expect(seeds.any((s) => s > 0x7FFFFFFF), isTrue, reason: 'upper half reachable');
  });
}
