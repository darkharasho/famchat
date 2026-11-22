import 'dart:convert';
import 'dart:typed_data';

import 'package:famchat/chat/chat_sync.dart';
import 'package:famchat/chat/plaintext.dart';
import 'package:famchat/crypto/encoding.dart';
import 'package:famchat/crypto/media.dart';
import 'package:famchat/media/media_api.dart';
import 'package:famchat/media/media_service.dart';
import 'package:flutter_test/flutter_test.dart';

const mediaKey = '01JC0000000000000000000000';

FileBody file({String name = 'Flight confirmation.pdf', String mime = 'application/pdf', String? replyTo}) => FileBody(
      mediaKey: mediaKey,
      key: Uint8List.fromList(List.filled(32, 1)),
      sha256: Uint8List.fromList(List.filled(32, 2)),
      name: name,
      bytes: 290816,
      mime: mime,
      replyTo: replyTo,
    );

Map<String, Object?> json(FileBody f) => f.toJson();

Plaintext decode(Map<String, Object?> j) => Plaintext.decode(utf8.encode(jsonEncode(j)));

void main() {
  test('round-trips through encode/decode', () {
    final f = file(replyTo: '01JC0000000000000000000001');
    final back = Plaintext.decode(f.encode()) as FileBody;
    expect(back.kind, 'file');
    expect(back.mediaKey, mediaKey);
    expect(back.key, f.key);
    expect(back.sha256, f.sha256);
    expect(back.name, 'Flight confirmation.pdf');
    expect(back.bytes, 290816);
    expect(back.mime, 'application/pdf');
    expect(back.replyTo, '01JC0000000000000000000001');
    expect(back.toJson(), f.toJson());
  });

  test('the wire shape', () {
    expect(json(file()), {
      'kind': 'file',
      'mediaKey': mediaKey,
      'key': b64url(Uint8List.fromList(List.filled(32, 1))),
      'sha256': b64url(Uint8List.fromList(List.filled(32, 2))),
      'name': 'Flight confirmation.pdf',
      'bytes': 290816,
      'mime': 'application/pdf',
    });
  });

  test('ref points at the blob as a file', () {
    final r = file().ref;
    expect(r.id, mediaKey);
    expect(r.purpose, MediaPurpose.file);
    expect(r.sha256, file().sha256);
  });

  test('the server and client limits are 64 MiB', () {
    expect(mediaKindLimits['file'], 64 * 1024 * 1024);
    expect(maxFileBytes, 64 * 1024 * 1024 - mediaOverhead);
    expect(ChatSync.mediaKinds, contains('file'));
  });

  for (final (name, patch) in <(String, Map<String, Object?>)>[
    ('bad mediaKey', {'mediaKey': '../x'}),
    ('missing mediaKey', {'mediaKey': null}),
    ('short key', {'key': b64url(Uint8List(16))}),
    ('bad sha256', {'sha256': 7}),
    ('zero bytes', {'bytes': 0}),
    ('bytes over 64 MiB', {'bytes': 64 * 1024 * 1024 + 1}),
    ('fractional bytes', {'bytes': 1.5}),
    ('bytes missing', {'bytes': null}),
    ('name missing', {'name': null}),
    ('name not a string', {'name': 7}),
  ]) {
    test('rejects $name', () {
      expect(() => decode({...json(file()), ...patch}), throwsFormatException);
    });
  }

  test('accepts exactly 64 MiB', () {
    expect((decode({...json(file()), 'bytes': 64 * 1024 * 1024}) as FileBody).bytes, 64 * 1024 * 1024);
  });

  test('a dirty name is cleaned, not refused', () {
    final f = decode({...json(file()), 'name': '../../etc/passwd'}) as FileBody;
    expect(f.name, isNot(contains('/')));
    expect(f.name, '....etcpasswd');
    expect((decode({...json(file()), 'name': ''}) as FileBody).name, 'file');
  });

  test('a missing or odd mime falls back to application/octet-stream', () {
    for (final m in [null, '', 7, 'pdf', 'text/plain; charset=utf-8', 'a/b\n', 'x/${'y' * 100}']) {
      expect((decode({...json(file()), 'mime': m}) as FileBody).mime, FileBody.defaultMime, reason: '$m');
    }
    expect((decode({...json(file()), 'mime': 'Application/VND.ms-excel'}) as FileBody).mime, 'application/vnd.ms-excel');
  });

  test('a bad replyTo is dropped and the file still shows', () {
    for (final r in [7, '', true]) {
      final f = decode({...json(file()), 'replyTo': r}) as FileBody;
      expect(f.replyTo, isNull);
      expect(f.name, 'Flight confirmation.pdf');
    }
  });

  group('cleanFileName', () {
    test('path separators never survive', () {
      for (final n in ['../../etc/passwd', r'..\..\Windows\system32', 'C:\\boot.ini', 'a/b\\c:d']) {
        final c = cleanFileName(n);
        expect(c, isNot(matches(RegExp(r'[/\\:]'))), reason: n);
      }
      expect(cleanFileName('a/b\\c:d.txt'), 'abcd.txt');
    });

    test('control characters and bidi marks are removed', () {
      expect(cleanFileName('in\u0000vo\u001Fice\u007F.pdf'), 'invoice.pdf');
      expect(cleanFileName('invoice\u202Efdp.exe'), 'invoicefdp.exe');
      expect(cleanFileName('\u2066a\u2067b\u2068c\u2069\u200E\u200F\u202A\u202B\u202C\u202D\u061C.txt'), 'abc.txt');
      expect(cleanFileName('line\nbreak\r\t.txt'), 'linebreak.txt');
      expect(cleanFileName('a\u2028b\u2029c\u0085.txt'), 'abc.txt');
    });

    test('trims, and empty or dots-only names become "file"', () {
      expect(cleanFileName('  report.pdf  '), 'report.pdf');
      expect(cleanFileName(''), 'file');
      expect(cleanFileName('   '), 'file');
      expect(cleanFileName('/\\:\u0000'), 'file');
      expect(cleanFileName('.'), 'file');
      expect(cleanFileName('..'), 'file');
      expect(cleanFileName('/../'), 'file');
      expect(cleanFileName('.bashrc'), '.bashrc');
    });

    test('trailing dots and spaces are stripped (Windows drops them when writing)', () {
      expect(cleanFileName('evil.exe.'), 'evil.exe');
      expect(cleanFileName('evil.bat..'), 'evil.bat');
      expect(cleanFileName('evil.exe. .'), 'evil.exe');
      expect(cleanFileName('evil.exe . . '), 'evil.exe');
      expect(cleanFileName('. . .'), 'file');
      expect(cleanFileName('${'a' * 300}.exe. '), endsWith('.exe'));
    });

    test('long names are cut to 255 characters, keeping the extension', () {
      final c = cleanFileName('${'a' * 400}.pdf');
      expect(c.length, 255);
      expect(c, endsWith('.pdf'));
      expect(c, startsWith('aaa'));
      // No short extension: just cut.
      final plain = cleanFileName('b' * 300);
      expect(plain, 'b' * 255);
      final longExt = cleanFileName('x.${'y' * 300}');
      expect(longExt.length, 255);
      // Counted in characters, not UTF-16 units: an emoji is never split.
      final emoji = cleanFileName('${'😀' * 300}.txt');
      expect(emoji.runes.length, 255);
      expect(emoji, endsWith('.txt'));
      expect(cleanFileName('${'a' * 251}.pdf'), '${'a' * 251}.pdf');
    });

    test('ordinary names are unchanged', () {
      for (final n in ['Flight confirmation.pdf', 'Résumé (final) v2.docx', '家族の写真.zip', 'archive.tar.gz']) {
        expect(cleanFileName(n), n);
      }
    });
  });
}
