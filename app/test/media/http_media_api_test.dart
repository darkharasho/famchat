import 'dart:convert';
import 'dart:typed_data';

import 'package:famchat/api/api_client.dart';
import 'package:famchat/api/models.dart';
import 'package:famchat/api/token_manager.dart';
import 'package:famchat/media/http_media_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

ApiClient client(Future<http.StreamedResponse> Function(http.BaseRequest r, Uint8List body) handler) {
  final api = ApiClient(
    client: MockClient.streaming((r, s) async => handler(r, await s.toBytes())),
    base: Uri.parse('https://famchat.dev'),
  );
  api.tokens = TokenManager(
    refreshCall: (_) async => throw StateError('no refresh'),
    readRefreshToken: () async => 'r',
    saveRefreshToken: (_) async {},
    onRevoked: () async {},
  )..setAccessToken('tok');
  return api;
}

http.StreamedResponse res(int status, List<int> body) => http.StreamedResponse(Stream.value(body), status);
http.StreamedResponse jsonRes(int status, Object body) => res(status, utf8.encode(jsonEncode(body)));

void main() {
  test('upload sends query, octet-stream body and content-length; 413 → too_large', () async {
    final bytes = Uint8List.fromList(List.generate(200000, (i) => i & 0xff));
    late http.BaseRequest seen;
    late Uint8List seenBody;
    var status = 201;
    final api = HttpMediaApi(client((r, body) async {
      seen = r;
      seenBody = body;
      return status == 201 ? jsonRes(201, {'key': 'K', 'bytes': bytes.length}) : jsonRes(status, {'error': 'too_large'});
    }));
    final progress = <int>[];
    await api.upload(key: 'K', chatId: 'C', kind: 'photo', messageId: 'M', bytes: bytes, onProgress: (s, t) {
      expect(t, bytes.length);
      progress.add(s);
    });
    expect(seen.method, 'POST');
    expect(seen.url.path, '/api/media');
    expect(seen.url.queryParameters, {'chatId': 'C', 'key': 'K', 'kind': 'photo', 'messageId': 'M'});
    expect(seen.headers['authorization'], 'Bearer tok');
    expect(seen.headers['content-type'], 'application/octet-stream');
    expect(seen.contentLength, bytes.length);
    expect(seenBody, bytes);
    expect(progress.last, bytes.length);
    expect(progress.length, greaterThan(1));

    status = 413;
    await expectLater(
      api.upload(key: 'K2', chatId: 'C', kind: 'photo', bytes: bytes),
      throwsA(isA<ApiException>().having((e) => (e.status, e.code), 'error', (413, 'too_large'))),
    );
    expect(seen.url.queryParameters.containsKey('messageId'), isFalse);
  });

  test('download returns bytes; 410 → media_expired', () async {
    final api = HttpMediaApi(client((r, _) async {
      if (r.url.path == '/api/media/OLD') return jsonRes(410, {'error': 'media_expired'});
      expect(r.url.path, '/api/media/NEW');
      expect(r.method, 'GET');
      return res(200, [1, 2, 3]);
    }));
    expect(await api.download('NEW'), [1, 2, 3]);
    await expectLater(
      api.download('OLD'),
      throwsA(isA<ApiException>().having((e) => (e.status, e.code), 'error', (410, 'media_expired'))),
    );
  });

  test('download refuses a body over 16 MiB', () async {
    const limit = 16 * 1024 * 1024;
    final api = HttpMediaApi(client((r, _) async {
      if (r.url.path == '/api/media/DECLARED') {
        return http.StreamedResponse(Stream.value([1]), 200, contentLength: limit + 1);
      }
      // No length declared: the body itself runs over.
      return http.StreamedResponse(Stream.fromIterable([Uint8List(limit), Uint8List(1)]), 200);
    }));
    for (final key in ['DECLARED', 'STREAMED']) {
      await expectLater(api.download(key), throwsA(isA<ApiException>().having((e) => e.code, 'code', 'too_large')), reason: key);
    }
  });

  test('usage parses the admin endpoint', () async {
    final api = HttpMediaApi(client((r, _) async {
      expect(r.url.path, '/api/admin/usage');
      return jsonRes(200, {'usedBytes': 5, 'capBytes': 8589934592, 'evictToBytes': 8053063680, 'files': 2, 'expiredFiles': 1});
    }));
    final u = await api.usage();
    expect((u.usedBytes, u.capBytes, u.evictToBytes, u.files, u.expiredFiles), (5, 8589934592, 8053063680, 2, 1));
  });
}
