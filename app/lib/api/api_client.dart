// HTTP calls to the FamChat API (server/src/routes). Authed calls retry once after a 401.
import 'dart:async';
import 'dart:convert';

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
