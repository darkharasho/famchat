// The device's sign-in state: restore at launch, join with an invite, sign out, revocation.
import 'dart:async';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../api/api_client.dart';
import '../api/models.dart';
import '../api/token_manager.dart';
import '../config.dart';
import '../crypto/device_cert.dart';
import '../crypto/encoding.dart';
import '../crypto/keys.dart';
import '../platform_info.dart';
import 'secure_kv.dart';
import 'stored_session.dart';

sealed class SessionState {
  const SessionState();
}

class SessionLoading extends SessionState {
  const SessionLoading();
}

class SignedOut extends SessionState {
  const SignedOut({this.message});

  /// Why the device was signed out, when it wasn't the user's choice.
  final String? message;
}

class SignedIn extends SessionState {
  const SignedIn(this.session);
  final StoredSession session;
}

/// Secure storage failed or didn't answer (e.g. no keyring on Linux).
class SessionUnavailable extends SessionState {
  const SessionUnavailable(this.message);
  final String message;
}

const revokedMessage = 'This device was signed out. Ask for a new invite to sign in again.';
const storageUnavailableMessage = "FamChat couldn't open this device's secure storage, where it keeps "
    'your keys. Try again in a moment. On Linux, check that a keyring such as GNOME Keyring or '
    'KWallet is installed and unlocked.';

final secureKvProvider = Provider<SecureKv>((ref) => FlutterSecureKv());

final httpClientProvider = Provider<http.Client>((ref) {
  final c = http.Client();
  ref.onDispose(c.close);
  return c;
});

final apiBaseProvider = Provider<Uri>((ref) => Uri.parse(apiBase));

final clockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

/// Bounds every storage call made while restoring, so a hung keyring can't block launch.
final storageTimeoutProvider = Provider<Duration>((ref) => const Duration(seconds: 10));

final refreshRetryDelaysProvider = Provider<List<Duration>>(
  (ref) => const [Duration(seconds: 1), Duration(seconds: 3), Duration(seconds: 8)],
);

/// The token from a `/join#<token>` link the web app was opened with.
final initialInviteTokenProvider = Provider<String?>((ref) => null);

final sessionStoreProvider = Provider<SessionStore>((ref) => SessionStore(ref.watch(secureKvProvider)));

final apiClientProvider = Provider<ApiClient>((ref) {
  final api = ApiClient(client: ref.watch(httpClientProvider), base: ref.watch(apiBaseProvider));
  SessionController ctl() => ref.read(sessionProvider.notifier);
  api.tokens = TokenManager(
    refreshCall: api.refresh,
    readRefreshToken: () => ctl()._readRefreshToken(),
    saveRefreshToken: (t) => ctl()._saveRefreshToken(t),
    onRevoked: () => ctl()._revoked(),
    now: ref.watch(clockProvider),
    retryDelays: ref.watch(refreshRetryDelaysProvider),
  );
  return api;
});

final sessionProvider = NotifierProvider<SessionController, SessionState>(SessionController.new);

class _PendingJoin {
  _PendingJoin(this.token, this.identity, this.device, this.cert);
  final String token;
  final SimpleKeyPair identity;
  final DeviceKeys device;
  final DeviceCert cert;
}

class SessionController extends Notifier<SessionState> {
  /// Keys generated for an invite whose redeem hasn't succeeded yet. Reused on retry so a lost
  /// response hits the server's same-keys idempotency instead of `invite_invalid`.
  _PendingJoin? _pending;

  /// Every change to the stored session runs here, one at a time, on the latest state, so a
  /// slow save can't write back an older refresh token or bring back a wiped session.
  Future<void> _writes = Future.value();

  /// The refresh token in memory is newer than the stored one (its save failed).
  bool _unsaved = false;

  SessionStore get _store => ref.read(sessionStoreProvider);
  Duration get _timeout => ref.read(storageTimeoutProvider);
  TokenManager? get _tokens => ref.read(apiClientProvider).tokens;

  Future<T> _serial<T>(Future<T> Function() f) {
    final r = _writes.then((_) => f());
    _writes = r.then((_) {}, onError: (_) {});
    return r;
  }

  @override
  SessionState build() {
    unawaited(_restore());
    return const SessionLoading();
  }

  Future<void> retryRestore() async {
    state = const SessionLoading();
    await _restore();
  }

  Future<void> _restore() async {
    await Future<void>.value(); // let build() return first
    SessionState next;
    try {
      final s = await _store.load().timeout(_timeout);
      next = s == null ? const SignedOut() : SignedIn(s);
    } catch (_) {
      next = const SessionUnavailable(storageUnavailableMessage);
    }
    if (ref.mounted) state = next;
  }

  /// Generates keys, redeems [token] and stores the session. Throws [ApiException] or
  /// [NetworkException]; calling again with the same token reuses the same keys.
  Future<void> join({required String token, required String deviceName}) async {
    var p = _pending;
    if (p == null || p.token != token) {
      final identity = await newIdentityKey();
      final device = await DeviceKeys.generate();
      final cert = await signDeviceCert(identity: identity, device: device);
      p = _pending = _PendingJoin(token, identity, device, cert);
    }
    final api = ref.read(apiClientProvider);
    final r = await api.redeemInvite(
      token: token,
      deviceName: deviceName.trim(),
      platform: serverPlatform(),
      cert: p.cert,
    );
    final seeds = await p.device.toStorage();
    await _signIn(StoredSession(
      userId: r.userId,
      deviceId: r.deviceId,
      deviceName: deviceName.trim(),
      refreshToken: r.refreshToken,
      isAdmin: r.isAdmin,
      name: null,
      identitySeed: b64url(await seedOf(p.identity)),
      encSeed: seeds['encSeed']!,
      signSeed: seeds['signSeed']!,
    ), r.accessToken);
  }

  /// Saves [session] (from a join or a pairing) and signs in with [accessToken].
  Future<void> adoptSession(StoredSession session, String accessToken) => _signIn(session, accessToken);

  Future<void> _signIn(StoredSession session, String accessToken) => _serial(() async {
        await _store.save(session).timeout(_timeout);
        _pending = null;
        _unsaved = false;
        ref.read(apiClientProvider).tokens!
          ..reset() // a refresh left over from an earlier session must not save into this one
          ..setAccessToken(accessToken);
        state = SignedIn(session);
      });

  /// Keeps the stored name and admin flag in step with `GET /api/me`.
  Future<void> updateProfile(Me me) => _serial(() async {
        final s = state;
        if (s is! SignedIn || s.session.userId != me.userId) return;
        if (s.session.name == me.name && s.session.isAdmin == me.isAdmin) return;
        final next = s.session.copyWith(name: me.name, isAdmin: me.isAdmin);
        state = SignedIn(next);
        await _store.save(next).timeout(_timeout);
      });

  /// Revokes this device on the server (best effort) and wipes its keys and tokens.
  Future<void> signOut() async {
    final s = state;
    if (s is SignedIn) {
      try {
        await ref.read(apiClientProvider).revokeDevice(s.session.deviceId).timeout(const Duration(seconds: 15));
      } catch (_) {
        // Offline or already revoked: the local wipe still happens.
      }
    }
    await _endSession(const SignedOut());
  }

  /// From the storage error screen, after the user confirmed: delete whatever is stored.
  Future<void> startOver() => _serial(() async {
        _detach();
        try {
          await _store.clear().timeout(_timeout);
        } catch (_) {
          // Storage is broken anyway; a new join overwrites the blob if it can.
        }
        state = const SignedOut();
      });

  Future<String?> _readRefreshToken() async {
    final s = state;
    if (s is! SignedIn) return null;
    if (_unsaved) return s.session.refreshToken;
    try {
      // Another tab may have rotated the token since this one loaded it.
      final stored = await _store.load().timeout(_timeout);
      if (stored != null && stored.deviceId == s.session.deviceId) return stored.refreshToken;
    } catch (_) {
      // Fall back to the token in memory.
    }
    return s.session.refreshToken;
  }

  /// The new token goes into memory first; if storage then fails or hangs, it stays there
  /// (and is used for the next refresh) rather than being lost.
  Future<void> _saveRefreshToken(String token) => _serial(() async {
        final s = state;
        if (s is! SignedIn) throw const SignedOutException();
        final next = s.session.copyWith(refreshToken: token);
        state = SignedIn(next);
        _unsaved = true;
        try {
          await _store.save(next).timeout(_timeout);
          _unsaved = false;
        } catch (_) {
          // Kept in memory; the next save retries.
        }
      });

  Future<void> _revoked() => _endSession(const SignedOut(message: revokedMessage));

  void _detach() {
    _pending = null;
    _unsaved = false;
    _tokens?.reset();
  }

  /// Wipes this session's stored blob (only if it is still this device's: on the web another
  /// tab may have stored a newer session) and moves to [next].
  Future<void> _endSession(SignedOut next) => _serial(() async {
        final s = state;
        _detach();
        if (s is SignedIn) {
          try {
            final stored = await _store.load().timeout(_timeout);
            if (stored == null || stored.deviceId == s.session.deviceId) {
              await _store.clear().timeout(_timeout);
            }
          } catch (_) {
            // Nothing more to do; the server side is already revoked or will reject the token.
          }
        }
        if (ref.mounted) state = next;
      });
}
