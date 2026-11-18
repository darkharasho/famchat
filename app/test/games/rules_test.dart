import 'package:famchat/games/rules.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('wireInt accepts ints and integral finite doubles only', () {
    expect(wireInt(3), 3);
    expect(wireInt(-2), -2);
    expect(wireInt(3.0), 3);
    expect(wireInt(-0.0), 0);
    expect(wireInt(3.5), isNull);
    expect(wireInt(double.nan), isNull);
    expect(wireInt(double.infinity), isNull);
    expect(wireInt(1e300), isNull);
    expect(wireInt('3'), isNull);
    expect(wireInt(null), isNull);
    expect(wireInt(true), isNull);
  });
}
