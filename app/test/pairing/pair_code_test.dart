import 'dart:math';
import 'dart:typed_data';

import 'package:famchat/pairing/pair_code.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const code = PairCode('7K2M', 'ABCDEFGH0123');

  test('display groups the 16 characters by four', () {
    expect(code.compact, '7K2MABCDEFGH0123');
    expect(code.display, '7K2M-ABCD-EFGH-0123');
  });

  test('parse accepts dashes, spaces, lowercase and look-alikes', () {
    for (final s in ['7K2M-ABCD-EFGH-0123', ' 7k2m abcd efgh 0123\n', '7K2MABCDEFGH0123', '7K2M-ABCD-EFGH-O123']) {
      final p = PairCode.parse(s);
      expect(p?.lookup, '7K2M', reason: s);
      expect(p?.secret, 'ABCDEFGH0123', reason: s);
    }
    expect(PairCode.parse('7K2M-ABCD-EFGH-IL23')?.secret, 'ABCDEFGH1123');
  });

  test('parse rejects wrong length or letters outside the alphabet', () {
    for (final s in ['', '7K2M-ABCD-EFGH-012', '7K2M-ABCD-EFGH-01234', '7K2M-ABCD-EFGH-012U', '7K2M_ABCD_EFGH_0123', 'hello']) {
      expect(PairCode.parse(s), isNull, reason: s);
    }
  });

  test('new secrets are 12 alphabet characters and differ', () {
    final a = newPairSecret(), b = newPairSecret(Random(1));
    expect(a, matches(RegExp(r'^[0-9A-HJKMNP-TV-Z]{12}$')));
    expect(b, matches(RegExp(r'^[0-9A-HJKMNP-TV-Z]{12}$')));
    expect(a, isNot(b));
  });

  test('QR round-trips and carries the ephemeral key', () {
    final eph = Uint8List.fromList(List.generate(32, (i) => i));
    final qr = PairQr(code, eph).encode();
    expect(qr, startsWith('famchat-pair:1:7K2MABCDEFGH0123:'));
    final back = PairQr.parse(qr)!;
    expect(back.code.compact, code.compact);
    expect(back.ephPub, eph);
  });

  test('QR garbage is rejected', () {
    for (final s in ['', 'famchat-pair:2:7K2MABCDEFGH0123:AAAA', 'famchat-pair:1:short:AAAA', 'https://example.com', 'famchat-pair:1:7K2MABCDEFGH0123:AAAA']) {
      expect(PairQr.parse(s), isNull, reason: s);
    }
  });

  test('pair input takes a QR or a typed code', () {
    final eph = Uint8List(32)..[0] = 7;
    final fromQr = parsePairInput(PairQr(code, eph).encode())!;
    expect(fromQr.code.compact, code.compact);
    expect(fromQr.ephPub, eph);
    final typed = parsePairInput('7k2m-abcd-efgh-0123')!;
    expect(typed.code.compact, code.compact);
    expect(typed.ephPub, isNull);
    expect(parsePairInput('nope'), isNull);
  });
}
