// HTTP calls to the FamChat API (server/src/routes). Authed calls retry once after a 401.
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../crypto/device_cert.dart';
import 'models.dart';
import 'token_manager.dart';

class ApiClient {
  ApiClient({required http.Client http, required Uri base, this.tokens})
      : _http = http,
        _base = base;

  final http.Client _http;
  final Uri _base;

  /// Needed for authed calls; set once the session exists.
  TokenManager? tokens;

  static const timeout = Duration(seconds: 20);

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
    final j = await _send('POST', '/auth/refresh', body: {'refreshToken': refreshToken});
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
  Future<Map<String, Object?>?> _send(String method, String path, {Object? body, String? bearer}) async {
    final req = http.Request(method, _base.replace(path: '/api$path'));
    if (bearer != null) req.headers['authorization'] = 'Bearer $bearer';
    if (body != null) {
      req.headers['content-type'] = 'application/json';
      req.body = jsonEncode(body);
    }
    final http.Response res;
    try {
      res = await http.Response.fromStream(await _http.send(req).timeout(timeout)).timeout(timeout);
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
