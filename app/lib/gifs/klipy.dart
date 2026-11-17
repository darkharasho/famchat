// GIF search through KLIPY (https://docs.klipy.com). Its terms have the app call KLIPY directly and
// load media from KLIPY's URLs (no proxying or re-hosting), so this runs on the device.
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;

import '../chat/plaintext.dart';

class GifException implements Exception {
  const GifException(this.message);
  final String message;
  @override
  String toString() => 'GifException: $message';
}

/// One result: a small preview for the grid and the size that gets sent.
class GifResult {
  const GifResult({required this.slug, required this.previewUrl, required this.previewWidth, required this.previewHeight, required this.body});
  final String slug, previewUrl;
  final int previewWidth, previewHeight;
  final GifBody body;
}

class GifPage {
  const GifPage(this.items, {required this.hasMore});
  final List<GifResult> items;
  final bool hasMore;
}

/// KLIPY's `customer_id`: a stable per-user value that isn't the user's id.
Future<String> klipyCustomerId(String userId) async {
  final h = await Sha256().hash(utf8.encode('famchat-klipy-v1:$userId'));
  return h.bytes.take(16).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

class KlipyClient {
  KlipyClient({required this.appKey, required this.customerId, http.Client? http, this.perPage = 24})
      : _http = http ?? _defaultClient;

  static final _defaultClient = http.Client();

  final String appKey, customerId;
  final int perPage;
  final http.Client _http;

  Uri _uri(String path, [Map<String, String> query = const {}]) => Uri.https(
        'api.klipy.com',
        '/api/v1/${Uri.encodeComponent(appKey)}/gifs/$path',
        {'customer_id': customerId, ...query},
      );

  Future<GifPage> trending({int page = 1}) => _page(_uri('trending', _list(page)));

  Future<GifPage> search(String q, {int page = 1}) => _page(_uri('search', {..._list(page), 'q': q}));

  Map<String, String> _list(int page) => {
        'page': '$page',
        'per_page': '$perPage',
        'format_filter': 'webp,gif',
        'content_filter': 'medium',
      };

  /// Tells KLIPY a GIF was sent (its share trigger). Best effort.
  Future<void> share(String slug) async {
    try {
      await _http.post(_uri('share/${Uri.encodeComponent(slug)}')).timeout(const Duration(seconds: 10));
    } catch (_) {
      // Only a ranking hint.
    }
  }

  Future<GifPage> _page(Uri uri) async {
    final http.Response res;
    try {
      res = await _http.get(uri).timeout(const Duration(seconds: 15));
    } catch (e) {
      throw GifException('network: $e');
    }
    if (res.statusCode != 200) throw GifException('status ${res.statusCode}');
    try {
      final j = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, Object?>;
      final data = j['data'] as Map<String, Object?>;
      final list = (data['data'] as List).cast<Map<String, Object?>>();
      final items = [for (final i in list) ?_result(i)];
      final hasNext = data['has_next'];
      return GifPage(items, hasMore: hasNext is bool ? hasNext : list.length >= perPage);
    } catch (e) {
      throw GifException('bad response: $e');
    }
  }

  /// Null for ads and items without a usable file.
  static GifResult? _result(Map<String, Object?> i) {
    if (i['type'] == 'ad') return null;
    final slug = i['slug'], file = i['file'];
    if (slug is! String || slug.isEmpty || file is! Map) return null;
    ({String url, int w, int h})? pick(List<String> sizes) {
      for (final size in sizes) {
        final s = file[size];
        if (s is! Map) continue;
        for (final format in const ['webp', 'gif']) {
          final f = s[format];
          if (f is Map && f['url'] is String && f['width'] is int && f['height'] is int && isKlipyMediaUrl(f['url'] as String)) {
            return (url: f['url'] as String, w: f['width'] as int, h: f['height'] as int);
          }
        }
      }
      return null;
    }

    final send = pick(const ['md', 'hd', 'sm']);
    final preview = pick(const ['sm', 'xs', 'md']);
    if (send == null || preview == null || send.w < 1 || send.h < 1) return null;
    final title = i['title'];
    return GifResult(
      slug: slug,
      previewUrl: preview.url,
      previewWidth: preview.w,
      previewHeight: preview.h,
      body: GifBody(
        slug: slug,
        title: title is String ? (title.length > 500 ? title.substring(0, 500) : title) : '',
        url: send.url,
        width: send.w.clamp(1, 4096),
        height: send.h.clamp(1, 4096),
      ),
    );
  }
}
