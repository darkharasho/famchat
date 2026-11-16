// HTTP calls to the FamChat API (server/src/routes). Authed calls retry once after a 401.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../crypto/device_cert.dart';
import 'models.dart';
import 'token_manager.dart';

class ApiClient {
  ApiClient({required this.client, required this.base, this.tokens});

  final http.Client client;

  /// Server origin, e.g. https://famchat.dev; paths go under /api.
  final Uri base;

  /// Needed for authed calls; set once the session exists.
  TokenManager? tokens;

  /// Whole-request deadline (send and body). On expiry the request is aborted, so a stalled
  /// request can't reach the server after its retry.
  static const timeout = Duration(seconds: 20);

  /// Shorter for refresh: with TokenManager's default retry delays (1, 3, 8 s), four attempts
  /// end within 44 s, inside the server's 60 s grace for a refresh whose response was lost.
  static const refreshTimeout = Duration(seconds: 8);

  Future<RedeemResult> redeemInvite({
    required String token,
    required String deviceName,
    required String platform,
    required DeviceCert cert,
  }) async {
    final j = await _send('POST', '/auth/invite/redeem', body: {
      'token': token,
      'deviceName': deviceName,
      'platform': platform,
      ...cert.toJson(),
    });
    return _parse(201, () => RedeemResult(
          userId: j!['userId'] as String,
          deviceId: j['deviceId'] as String,
          isAdmin: j['isAdmin'] as bool,
          accessToken: j['accessToken'] as String,
          refreshToken: j['refreshToken'] as String,
        ));
  }

  Future<TokenPair> refresh(String refreshToken) async {
    final j = await _send('POST', '/auth/refresh', body: {'refreshToken': refreshToken}, timeout: refreshTimeout);
    return _parse(200, () => TokenPair(j!['accessToken'] as String, j['refreshToken'] as String));
  }

  Future<Me> me() => _authed((t) async {
        final j = await _send('GET', '/me', bearer: t);
        return _parse(200, () => Me(
              userId: j!['userId'] as String,
              deviceId: j['deviceId'] as String,
              name: j['name'] as String,
              isAdmin: j['isAdmin'] as bool,
            ));
      });

  Future<List<DeviceInfo>> listDevices() => _authed((t) async {
        final j = await _send('GET', '/devices', bearer: t);
        return _parse(200, () => [
              for (final d in (j!['devices'] as List).cast<Map<String, Object?>>())
                DeviceInfo(
                  id: d['id'] as String,
                  name: d['name'] as String,
                  platform: d['platform'] as String,
                  createdAt: DateTime.fromMillisecondsSinceEpoch(d['createdAt'] as int),
                  lastSeen: DateTime.fromMillisecondsSinceEpoch(d['lastSeen'] as int),
                  current: d['current'] as bool,
                ),
            ]);
      });

  Future<void> revokeDevice(String id) =>
      _authed((t) => _send('DELETE', '/devices/${Uri.encodeComponent(id)}', bearer: t));

  Future<Invite> createInvite(String name) => _authed((t) async {
        final j = await _send('POST', '/admin/invites', body: {'name': name}, bearer: t);
        return _parse(201, () => Invite(
              inviteToken: j!['inviteToken'] as String,
              inviteUrl: j['inviteUrl'] as String,
              expiresAt: DateTime.fromMillisecondsSinceEpoch(j['expiresAt'] as int),
            ));
      });

  /// An authed call for routes without a typed method here (the chat API). Returns the decoded JSON
  /// object, or null for an empty body.
  Future<Map<String, Object?>?> authedJson(String method, String path, {Object? body, Map<String, String>? query}) =>
      _authed((t) => _send(method, path, body: body, bearer: t, query: query));

  /// Media transfers get longer than [timeout]: 30 s plus 1 s per 50 kB.
  static Duration mediaTimeout(int bytes) => Duration(seconds: 30 + bytes ~/ 50000);

  /// Download deadline when the size isn't known up front (blobs are at most 16 MiB).
  static const downloadTimeout = Duration(minutes: 5);

  /// Authed POST of raw bytes (`application/octet-stream`, `Content-Length` set), streamed in
  /// 64 KiB chunks; [onProgress] gets the bytes the network has taken so far. Returns the JSON body.
  Future<Map<String, Object?>?> authedUpload(
    String path, {
    Map<String, String>? query,
    required Uint8List bytes,
    void Function(int sent, int total)? onProgress,
  }) =>
      _authed((t) async {
        final res = await _raw('POST', path, bearer: t, query: query, upload: bytes, onProgress: onProgress,
            timeout: mediaTimeout(bytes.length));
        return _json(res);
      });

  /// Authed GET of a raw body (media downloads).
  Future<Uint8List> authedBytes(String path) => _authed((t) async {
        final res = await _raw('GET', path, bearer: t, timeout: downloadTimeout);
        return res.bodyBytes;
      });

  /// Sends a request whose body (if any) is raw bytes. Status ≥ 400 throws [ApiException].
  Future<http.Response> _raw(
    String method,
    String path, {
    required String bearer,
    Map<String, String>? query,
    Uint8List? upload,
    void Function(int sent, int total)? onProgress,
    required Duration timeout,
  }) async {
    final abort = Completer<void>();
    final url = base.replace(path: '/api$path', queryParameters: query == null || query.isEmpty ? null : query);
    final http.BaseRequest req = upload == null
        ? http.AbortableRequest(method, url, abortTrigger: abort.future)
        : _UploadRequest(method, url, upload, onProgress, abort.future);
    req.headers['authorization'] = 'Bearer $bearer';
    final http.Response res;
    try {
      res = await (() async => http.Response.fromStream(await client.send(req)))().timeout(timeout, onTimeout: () {
        if (!abort.isCompleted) abort.complete();
        throw TimeoutException('request timed out', timeout);
      });
    } on http.ClientException catch (e) {
      throw NetworkException(e);
    } on TimeoutException catch (e) {
      throw NetworkException(e);
    }
    if (res.statusCode >= 400) throw ApiException(res.statusCode, _errorCode(res.body));
    return res;
  }

  static String _errorCode(String body) {
    try {
      final j = jsonDecode(body);
      if (j is Map && j['error'] is String) return j['error'] as String;
    } on FormatException {
      // not JSON
    }
    return 'unknown';
  }

  static Map<String, Object?>? _json(http.Response res) {
    if (res.body.isEmpty) return null;
    final Object? j;
    try {
      j = jsonDecode(res.body);
    } on FormatException {
      throw ApiException(res.statusCode, 'bad_response');
    }
    if (j is! Map<String, Object?>) throw ApiException(res.statusCode, 'bad_response');
    return j;
  }

  Future<T> _authed<T>(Future<T> Function(String accessToken) call) async {
    final tm = tokens;
    if (tm == null) throw const SignedOutException();
    final token = await tm.accessToken();
    try {
      return await call(token);
    } on ApiException catch (e) {
      if (e.status != 401) rethrow;
      return call(await tm.refreshAfter401(token));
    }
  }

  /// Wraps a shape mismatch in a success body as `bad_response`.
  T _parse<T>(int status, T Function() f) {
    try {
      return f();
    } on TypeError {
      throw ApiException(status, 'bad_response');
    }
  }

  /// The decoded JSON object, or null for an empty body. Errors throw [ApiException] or
  /// [NetworkException].
  Future<Map<String, Object?>?> _send(
    String method,
    String path, {
    Object? body,
    String? bearer,
    Duration timeout = timeout,
    Map<String, String>? query,
  }) async {
    final abort = Completer<void>();
    final url = base.replace(path: '/api$path', queryParameters: query == null || query.isEmpty ? null : query);
    final req = http.AbortableRequest(method, url, abortTrigger: abort.future);
    if (bearer != null) req.headers['authorization'] = 'Bearer $bearer';
    if (body != null) {
      req.headers['content-type'] = 'application/json';
      req.body = jsonEncode(body);
    }
    Future<http.Response> fetch() async => http.Response.fromStream(await client.send(req));
    final http.Response res;
    try {
      res = await fetch().timeout(timeout, onTimeout: () {
        if (!abort.isCompleted) abort.complete();
        throw TimeoutException('request timed out', timeout);
      });
    } on http.ClientException catch (e) {
      throw NetworkException(e);
    } on TimeoutException catch (e) {
      throw NetworkException(e);
    }
    Object? json;
    if (res.body.isNotEmpty) {
      try {
        json = jsonDecode(res.body);
      } on FormatException {
        json = null;
      }
    }
    if (res.statusCode >= 400) {
      final code = json is Map && json['error'] is String ? json['error'] as String : 'unknown';
      throw ApiException(res.statusCode, code);
    }
    if (json == null) return null;
    if (json is! Map<String, Object?>) throw ApiException(res.statusCode, 'bad_response');
    return json;
  }
}

/// A raw-bytes body produced chunk by chunk, so progress follows what the client consumed
/// (on the web the browser client buffers the whole body first, so progress jumps).
class _UploadRequest extends http.BaseRequest with http.Abortable {
  _UploadRequest(super.method, super.url, this.bytes, this.onProgress, this.abortTrigger) {
    headers['content-type'] = 'application/octet-stream';
    contentLength = bytes.length;
  }

  final Uint8List bytes;
  final void Function(int sent, int total)? onProgress;

  @override
  final Future<void>? abortTrigger;

  static const chunk = 64 * 1024;

  @override
  http.ByteStream finalize() {
    super.finalize();
    return http.ByteStream(_chunks());
  }

  Stream<List<int>> _chunks() async* {
    for (var i = 0; i < bytes.length; i += chunk) {
      final end = i + chunk < bytes.length ? i + chunk : bytes.length;
      yield Uint8List.sublistView(bytes, i, end);
      onProgress?.call(end, bytes.length);
    }
  }
}
