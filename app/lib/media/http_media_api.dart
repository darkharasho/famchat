import 'dart:typed_data';

import '../api/api_client.dart';
import '../crypto/media.dart';
import 'media_api.dart';

class HttpMediaApi implements MediaApi {
  HttpMediaApi(this._api);

  final ApiClient _api;

  @override
  Future<void> upload({
    required String key,
    required String chatId,
    required String kind,
    String? messageId,
    required Uint8List bytes,
    void Function(int sent, int total)? onProgress,
  }) =>
      _api.authedUpload('/media', query: {
        'chatId': chatId,
        'key': key,
        'kind': kind,
        'messageId': ?messageId,
      }, bytes: bytes, onProgress: onProgress);

  @override
  Future<Uint8List> download(String key) =>
      _api.authedBytes('/media/${Uri.encodeComponent(key)}', maxBytes: maxMediaBlobBytes);

  @override
  Future<MediaUsage> usage() async =>
      MediaUsage.fromJson(await _api.authedJson('GET', '/admin/usage') ?? (throw const FormatException('empty body')));
}
