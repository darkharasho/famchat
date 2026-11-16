import 'package:famchat/crypto/encoding.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('b64url round-trips and drops padding', () {
    expect(b64url([0xff]), '_w');
    expect(b64urlDecode('_w'), [0xff]);
    expect(b64urlDecode(b64url([0xfb, 0xff, 1])), [0xfb, 0xff, 1]);
  });

  test('bad base64 throws CryptoFailure', () {
    expect(() => b64urlDecode('*'), throwsA(isA<CryptoFailure>()));
    expect(() => b64urlDecode('a'), throwsA(isA<CryptoFailure>()));
  });

  test('ByteWriter layout', () {
    final out = (ByteWriter('d')
          ..str('ab')
          ..u32(1)
          ..u8(2)
          ..bytes([9]))
        .finish();
    expect(out, [0x64, 0, 2, 0x61, 0x62, 0, 0, 0, 1, 2, 9]);
  });

  test('str length prefix rejects >65535 bytes', () {
    final w = ByteWriter('d')..str('x' * 65535);
    expect(w.finish().length, 1 + 2 + 65535);
    expect(() => ByteWriter('d').str('x' * 65536), throwsArgumentError);
  });

  test('u32 and u8 reject out-of-range values', () {
    expect(() => ByteWriter('d').u32(-1), throwsArgumentError);
    expect(() => ByteWriter('d').u32(0x100000000), throwsArgumentError);
    expect(() => ByteWriter('d').u8(256), throwsArgumentError);
    expect((ByteWriter('')..u32(0xffffffff)).finish(), [0xff, 0xff, 0xff, 0xff]);
  });
}
