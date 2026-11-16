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

  /// [resetClaimSig] (base64url) is required for a reset link: the claim key's signature over the new identity key.
  Future<RedeemResult> redeemInvite({
    required String token,
    required String deviceName,
    required String platform,
    required DeviceCert cert,
    String? resetClaimSig,
  }) async {
    final j = await _send('POST', '/auth/invite/redeem', body: {
      'token': token,
      'deviceName': deviceName,
      'platform': platform,
      ...cert.toJson(),
      'resetClaimSig': ?resetClaimSig,
    });
    return _parse(201, () => _redeemResult(j!));
  }

  static RedeemResult _redeemResult(Map<String, Object?> j) => RedeemResult(
        userId: j['userId'] as String,
        deviceId: j['deviceId'] as String,
        isAdmin: j['isAdmin'] as bool,
        accessToken: j['accessToken'] as String,
        refreshToken: j['refreshToken'] as String,
      );

  /// Unauthenticated: whose recovery key [recoveryPub] (base64url) is, and their identity key now.
  Future<({String userId, String identityPub})> recoverLookup(String recoveryPub) async {
    final j = await _send('POST', '/auth/recover/lookup', body: {'recoveryPub': recoveryPub});
    return _parse(200, () => (userId: j!['userId'] as String, identityPub: j['identityPub'] as String));
  }

  /// Unauthenticated: signs a new device in to the admin account the recovery key belongs to.
  /// [body] holds the signed reset statement, the claim and the new device's keys (docs/protocol.md).
  Future<RedeemResult> recover(Map<String, Object?> body) async {
    final j = await _send('POST', '/auth/recover', body: body);
    return _parse(201, () => _redeemResult(j!));
  }

  /// Admin: resets [userId] with a statement signed by this user's identity key. Returns the
  /// server's invite URL (without the claim seed).
  Future<({String resetId, String inviteUrl, DateTime expiresAt})> resetUser(
    String userId, {
    required String resetId,
    required String oldIdentityPub,
    required String claimPub,
    required int createdAt,
    required String sig,
  }) =>
      _authed((t) async {
        final j = await _send('POST', '/admin/users/${Uri.encodeComponent(userId)}/reset', bearer: t, body: {
          'resetId': resetId,
          'oldIdentityPub': oldIdentityPub,
          'claimPub': claimPub,
          'createdAt': createdAt,
          'sig': sig,
        });
        return _parse(201, () => (
              resetId: j!['resetId'] as String,
              inviteUrl: j['inviteUrl'] as String,
              expiresAt: DateTime.fromMillisecondsSinceEpoch(j['expiresAt'] as int),
            ));
      });

  /// Admin: makes [userId] an admin too.
  Future<void> makeAdmin(String userId) =>
      _authed((t) => _send('POST', '/admin/users/${Uri.encodeComponent(userId)}/admin', bearer: t));

  /// Admin: registers this admin's recovery key (base64url) with the identity key's signature over it.
  Future<void> setRecoveryKey({required String recoveryPub, required String sig}) =>
      _authed((t) => _send('POST', '/admin/recovery-key', bearer: t, body: {'recoveryPub': recoveryPub, 'sig': sig}));

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
              recoveryCodeSet: j['recoveryCodeSet'] == true,
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

  // --- pairing (docs/protocol.md "Pairing a new device") ---

  /// Unauthenticated: the new device opens a session.
  Future<PairStartResult> pairStart({
    required String ephPub,
    required String encPub,
    required String signPub,
    required String keysMac,
    required String deviceName,
    required String platform,
  }) async {
    final j = await _send('POST', '/devices/pair/start', body: {
      'ephPub': ephPub,
      'encPub': encPub,
      'signPub': signPub,
      'keysMac': keysMac,
      'deviceName': deviceName,
      'platform': platform,
    });
    return _parse(201, () => PairStartResult(
          sessionId: j!['sessionId'] as String,
          lookup: j['code'] as String,
          secret: j['secret'] as String,
          deviceId: j['deviceId'] as String,
          expiresIn: Duration(milliseconds: j['expiresIn'] as int),
        ));
  }

  /// Unauthenticated: the new device asks whether it was approved.
  Future<PairClaim> pairClaim(String sessionId, String secret) async {
    final j = await _send('POST', '/devices/pair/claim', body: {'sessionId': sessionId, 'secret': secret});
    return _parse(200, () {
      if (j!['status'] == 'waiting') return const PairWaiting();
      if (j['status'] != 'approved') throw TypeError();
      return PairApproved(
        RedeemResult(
          userId: j['userId'] as String,
          deviceId: j['deviceId'] as String,
          isAdmin: j['isAdmin'] as bool,
          accessToken: j['accessToken'] as String,
          refreshToken: j['refreshToken'] as String,
        ),
        j['bundle'] as String,
      );
    });
  }

  Future<void> pairCancel(String sessionId, String secret) =>
      _send('POST', '/devices/pair/cancel', body: {'sessionId': sessionId, 'secret': secret});

  /// Authed: the approving device fetches the session by its lookup code.
  Future<PairSessionInfo> pairLookup(String lookup) => _authed((t) async {
        final j = await _send('GET', '/devices/pair/${Uri.encodeComponent(lookup)}', bearer: t);
        return _parse(200, () {
          final s = j!['session'] as Map<String, Object?>;
          return PairSessionInfo(
            lookup: s['code'] as String,
            deviceId: s['deviceId'] as String,
            ephPub: s['ephPub'] as String,
            encPub: s['encPub'] as String,
            signPub: s['signPub'] as String,
            keysMac: s['keysMac'] as String,
            deviceName: s['deviceName'] as String,
            platform: s['platform'] as String,
          );
        });
      });

  /// Authed: approves the session with the new device's cert and the sealed bundle (base64url).
  Future<void> pairApprove(String lookup, {required String deviceId, required String certSig, required String bundle}) =>
      _authed((t) => _send('POST', '/devices/pair/${Uri.encodeComponent(lookup)}/approve',
          body: {'deviceId': deviceId, 'certSig': certSig, 'bundle': bundle}, bearer: t));

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

  /// Authed GET of a raw body (media downloads). A body over [maxBytes] is abandoned with
  /// `ApiException(status, 'too_large')`.
  Future<Uint8List> authedBytes(String path, {int? maxBytes}) => _authed((t) async {
        final res = await _raw('GET', path, bearer: t, timeout: downloadTimeout, maxResponseBytes: maxBytes);
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
    int? maxResponseBytes,
  }) async {
    final abort = Completer<void>();
    final url = base.replace(path: '/api$path', queryParameters: query == null || query.isEmpty ? null : query);
    final http.BaseRequest req = upload == null
        ? http.AbortableRequest(method, url, abortTrigger: abort.future)
        : _UploadRequest(method, url, upload, onProgress, abort.future);
    req.headers['authorization'] = 'Bearer $bearer';
    Future<http.Response> fetch() async {
      final s = await client.send(req);
      final max = maxResponseBytes;
      if (max == null) return http.Response.fromStream(s);
      Never tooLarge() {
        if (!abort.isCompleted) abort.complete();
        throw ApiException(s.statusCode, 'too_large');
      }

      if ((s.contentLength ?? 0) > max) tooLarge();
      final b = BytesBuilder(copy: false);
      await for (final chunk in s.stream) {
        b.add(chunk);
        if (b.length > max) tooLarge();
      }
      return http.Response.bytes(b.takeBytes(), s.statusCode, headers: s.headers, request: s.request);
    }

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
