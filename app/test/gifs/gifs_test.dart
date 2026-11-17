import 'dart:convert';

import 'package:famchat/chat/plaintext.dart';
import 'package:famchat/gifs/klipy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Map<String, Object?> media(String name, int w, int h) => {'url': 'https://static.klipy.com/ii/x/$name', 'width': w, 'height': h, 'size': 100};

Map<String, Object?> item(String slug, {String type = 'gif'}) => {
      'id': 1,
      'slug': slug,
      'title': 'Title $slug',
      'type': type,
      'file': {
        'md': {'webp': media('$slug-md.webp', 400, 300), 'gif': media('$slug-md.gif', 400, 300)},
        'sm': {'webp': media('$slug-sm.webp', 200, 150), 'jpg': media('$slug-sm.jpg', 200, 150)},
      },
    };

void main() {
  group('GifBody', () {
    const body = GifBody(slug: 'hello-hi-662', title: 'Hello', url: 'https://static.klipy.com/ii/a/b.webp', width: 498, height: 400);

    test('round trip', () {
      expect(Plaintext.decode(body.encode()).toJson(), body.toJson());
    });

    test('only https KLIPY media and sane sizes are accepted', () {
      Map<String, Object?> j([Map<String, Object?> change = const {}]) => {...body.toJson(), ...change};
      List<int> bytes(Map<String, Object?> m) => utf8.encode(jsonEncode(m));
      expect(Plaintext.decode(bytes(j({'url': 'https://static2.klipy.com/x.gif'}))), isA<GifBody>());
      for (final bad in [
        {'url': 'http://static.klipy.com/x.gif'},
        {'url': 'https://evil.com/x.gif'},
        {'url': 'https://klipy.com.evil.com/x.gif'},
        {'url': 'https://static.klipy.com@evil.com/x.gif'},
        {'width': 0},
        {'height': 50000},
        {'slug': ''},
      ]) {
        expect(() => Plaintext.decode(bytes(j(bad))), throwsFormatException, reason: '$bad');
      }
    });
  });

  group('KlipyClient', () {
    test('trending and search pick a preview and a send size, and skip ads', () async {
      final seen = <Uri>[];
      final client = KlipyClient(
        appKey: 'KEY',
        customerId: 'cust',
        http: MockClient((req) async {
          seen.add(req.url);
          return http.Response(
            jsonEncode({
              'result': true,
              'data': {
                'data': [item('a'), item('ad1', type: 'ad'), item('b')],
                'current_page': 1,
                'per_page': 24,
                'has_next': true,
              },
            }),
            200,
          );
        }),
      );
      final page = await client.search('cats & dogs');
      expect(page.items.map((g) => g.slug), ['a', 'b']);
      expect(page.hasMore, isTrue);
      final a = page.items.first;
      expect(a.previewUrl, 'https://static.klipy.com/ii/x/a-sm.webp');
      expect((a.body.url, a.body.width, a.body.height, a.body.title), ('https://static.klipy.com/ii/x/a-md.webp', 400, 300, 'Title a'));
      expect(seen.single.path, '/api/v1/KEY/gifs/search');
      expect(seen.single.queryParameters, containsPair('q', 'cats & dogs'));
      expect(seen.single.queryParameters, containsPair('customer_id', 'cust'));
      expect(seen.single.queryParameters, containsPair('page', '1'));
      await client.trending(page: 2);
      expect(seen.last.path, '/api/v1/KEY/gifs/trending');
      expect(seen.last.queryParameters['page'], '2');
    });

    test('a failed request throws GifException', () async {
      final client = KlipyClient(appKey: 'K', customerId: 'c', http: MockClient((_) async => http.Response('nope', 500)));
      expect(client.trending(), throwsA(isA<GifException>()));
    });

    test('share is reported for the sent GIF and failures are ignored', () async {
      final seen = <http.Request>[];
      final client = KlipyClient(appKey: 'K', customerId: 'c', http: MockClient((r) async {
        seen.add(r);
        return http.Response('', 500);
      }));
      await client.share('hello-1');
      expect((seen.single.method, seen.single.url.path), ('POST', '/api/v1/K/gifs/share/hello-1'));
      expect(seen.single.url.queryParameters['customer_id'], 'c');
    });

    test('customer ids are a stable hash, not the user id', () async {
      final a = await klipyCustomerId('01JUSER');
      expect(a, await klipyCustomerId('01JUSER'));
      expect(a, isNot(contains('01JUSER')));
      expect(a, isNot(await klipyCustomerId('01JOTHER')));
    });
  });
}
