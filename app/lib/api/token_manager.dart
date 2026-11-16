// Holds the access token and refreshes it: one refresh at a time, retried with the same
// refresh token on network errors so a lost response lands in the server's 60 s grace window.
import 'dart:async';
import 'dart:convert';

import 'models.dart';

class TokenManager {
  TokenManager({
    required this.refreshCall,
    required this.readRefreshToken,
    required this.saveRefreshToken,
    required this.onRevoked,
    DateTime Function()? now,
    this.retryDelays = const [Duration(seconds: 1), Duration(seconds: 3), Duration(seconds: 8)],
  }) : _now = now ?? DateTime.now;

  /// `POST /api/auth/refresh`.
  final Future<TokenPair> Function(String refreshToken) refreshCall;

  /// Reads the stored refresh token each time, so a rotation by another tab is seen.
  final Future<String?> Function() readRefreshToken;

  /// Must persist the token before it returns; the new access token is used only after.
  final Future<void> Function(String refreshToken) saveRefreshToken;

  /// Called once when the server refuses the refresh token (device revoked).
  final Future<void> Function() onRevoked;

  final List<Duration> retryDelays;
  final DateTime Function() _now;

  /// Refresh this long before the access token's `exp`.
  static const early = Duration(seconds: 60);

  String? _access;
  Future<String>? _inflight;

  void setAccessToken(String? token) => _access = token;

  /// A usable access token, refreshing first if there is none or it is about to expire.
  Future<String> accessToken() {
    final a = _access;
    if (a != null && !_expiresSoon(a)) return Future.value(a);
    return _refresh();
  }

  /// After the server rejected [rejected] with 401. If another call already refreshed,
  /// returns the newer token without refreshing again.
  Future<String> refreshAfter401(String rejected) {
    final a = _access;
    if (a != null && a != rejected) return Future.value(a);
    return _refresh();
  }

  Future<String> _refresh() => _inflight ??= _doRefresh().whenComplete(() => _inflight = null);

  Future<String> _doRefresh() async {
    final first = await readRefreshToken();
    if (first == null) {
      _access = null;
      throw const SignedOutException();
    }
    var refreshToken = first;
    var rereadAfter401 = false;
    for (var attempt = 0;; attempt++) {
      Object error;
      try {
        final pair = await refreshCall(refreshToken);
        await saveRefreshToken(pair.refreshToken);
        _access = pair.accessToken;
        return pair.accessToken;
      } on ApiException catch (e) {
        if (e.status == 401) {
          // Another tab may have rotated the shared token after we read it: try that once.
          final latest = rereadAfter401 ? null : await readRefreshToken();
          rereadAfter401 = true;
          if (latest != null && latest != refreshToken) {
            refreshToken = latest;
            attempt--;
            continue;
          }
          _access = null;
          await onRevoked();
          throw const SignedOutException();
        }
        if (e.status < 500) rethrow;
        error = e;
      } on NetworkException catch (e) {
        error = e;
      }
      if (attempt >= retryDelays.length) throw error;
      await Future<void>.delayed(retryDelays[attempt]);
    }
  }

  bool _expiresSoon(String jwt) {
    final exp = _exp(jwt);
    if (exp == null) return false; // unknown format: rely on the server's 401
    return !_now().add(early).isBefore(exp);
  }

  static DateTime? _exp(String jwt) {
    final parts = jwt.split('.');
    if (parts.length != 3) return null;
    try {
      final payload = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))));
      final exp = payload is Map ? payload['exp'] : null;
      return exp is int ? DateTime.fromMillisecondsSinceEpoch(exp * 1000) : null;
    } catch (_) {
      return null;
    }
  }
}
