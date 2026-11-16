// The new device's side of pairing: make keys and a secret, open a session, show the code and QR,
// poll until another device of the user approves, then verify the bundle and produce a session.
// In reverse pairing the code (and so the secret) comes from the other device's offer instead, and
// nothing is shown here while waiting.
// Nothing is stored here; the caller installs the handover and saves the session.
import 'dart:async';

import 'package:cryptography/cryptography.dart';

import '../api/api_client.dart';
import '../api/models.dart';
import '../crypto/encoding.dart';
import '../crypto/keys.dart';
import '../crypto/pairing.dart';
import '../session/stored_session.dart';
import 'bundle.dart';
import 'pair_code.dart';

sealed class PairState {
  const PairState();
}

class PairIdle extends PairState {
  const PairIdle();
}

class PairStarting extends PairState {
  const PairStarting();
}

/// Show [code] (typed) and [qr] (scanned) until [expiresAt].
class PairShowing extends PairState {
  const PairShowing(this.code, this.qr, this.expiresAt);
  final PairCode code;
  final String qr;
  final DateTime expiresAt;
}

/// Took the other device's offer (reverse pairing); waiting for approval there until [expiresAt].
class PairJoined extends PairState {
  const PairJoined(this.expiresAt);
  final DateTime expiresAt;
}

/// Approved; verifying the bundle and setting up.
class PairFinishing extends PairState {
  const PairFinishing();
}

class PairDone extends PairState {
  const PairDone(this.device);
  final PairedDevice device;
}

class PairExpired extends PairState {
  const PairExpired();
}

class PairCancelled extends PairState {
  const PairCancelled();
}

class PairFailed extends PairState {
  const PairFailed(this.message);
  final String message;
}

/// What a successful pairing yields: the session to save (not saved yet), a fresh access token,
/// and the verified handover to install.
class PairedDevice {
  const PairedDevice({required this.session, required this.accessToken, required this.bundle});
  final StoredSession session;
  final String accessToken;
  final PairBundle bundle;
}

const unknownOfferMessage = 'No device is showing that code. Codes expire after 5 minutes; '
    'get a new one on your other device.';

const forgedBundleMessage = "The approval couldn't be verified, so nothing was set up. Start again, "
    'and approve from one of your own devices.';

class NewDevicePairing {
  NewDevicePairing({
    required this.api,
    required this.deviceName,
    required this.platform,
    this.pollEvery = const Duration(seconds: 2),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final ApiClient api;
  final String deviceName, platform;
  final Duration pollEvery;

  /// How long past expiry to keep retrying when the server can't be reached.
  static const unreachableGrace = Duration(minutes: 1);
  final DateTime Function() _now;

  final _states = StreamController<PairState>.broadcast();
  PairState _state = const PairIdle();
  bool _stopped = false;
  PairStartResult? _session;
  Timer? _timer;
  Completer<void>? _sleeping;

  Stream<PairState> get states => _states.stream;
  PairState get state => _state;

  void _set(PairState s) {
    _state = s;
    if (!_states.isClosed) _states.add(s);
  }

  /// Opens the session and shows the code; polling then runs until done, expired, failed or
  /// cancelled. Errors while opening the session end in [PairFailed].
  ///
  /// With [offer] (a code scanned or typed from a signed-in device) the session takes that offer and
  /// uses its secret, and the state is [PairJoined] instead of [PairShowing].
  Future<void> start({PairCode? offer}) async {
    _set(const PairStarting());
    final eph = await X25519().newKeyPair();
    final keys = await DeviceKeys.generate();
    final secret = offer?.secret ?? newPairSecret();
    final ephPub = await publicKeyOf(eph), encPub = await keys.encPub(), signPub = await keys.signPub();
    final PairStartResult s;
    try {
      s = await api.pairStart(
        ephPub: b64url(ephPub),
        encPub: b64url(encPub),
        signPub: b64url(signPub),
        keysMac: b64url(await pairKeysMac(
            secret: secret, ephPub: ephPub, encPub: encPub, signPub: signPub, deviceName: deviceName, platform: platform)),
        deviceName: deviceName,
        platform: platform,
        offer: offer?.lookup,
      );
    } catch (e) {
      if (!_stopped) {
        _set(PairFailed(
            offer != null && e is ApiException && e.code == 'not_found' ? unknownOfferMessage : startErrorMessage(e)));
      }
      return;
    }
    _session = s;
    if (_stopped) return _cancelOnServer(); // cancelled while the session was being opened
    final code = PairCode(s.lookup, secret);
    final expiresAt = _now().add(s.expiresIn);
    _set(offer != null ? PairJoined(expiresAt) : PairShowing(code, PairQr(code, ephPub).encode(), expiresAt));
    unawaited(_poll(s, code, eph, keys, expiresAt));
  }

  static String startErrorMessage(Object e) => switch (e) {
        ApiException(code: 'rate_limited') => 'Too many tries. Wait a few minutes and try again.',
        NetworkException() => "Couldn't reach FamChat. Check your connection and try again.",
        ApiException(:final code) => 'Something went wrong ($code). Please try again.',
        _ => 'Something went wrong. Please try again.',
      };

  Future<void> _poll(PairStartResult s, PairCode code, SimpleKeyPair eph, DeviceKeys keys, DateTime expiresAt) async {
    while (!_stopped) {
      await _sleep();
      if (_stopped) return;
      final PairClaim claim;
      try {
        claim = await api.pairClaim(s.sessionId, s.secret);
      } on ApiException catch (e) {
        if (e.code == 'pairing_invalid' || e.code == 'not_found') return _expire(cancel: false);
        if (_now().isAfter(expiresAt.add(unreachableGrace))) return _expire(cancel: false);
        continue; // 5xx and the like: keep trying
      } on NetworkException {
        // A lost claim response is safe to retry with the same secret. Past expiry (plus a grace
        // for an approval whose answer we haven't seen yet) the server has given up too.
        if (_now().isAfter(expiresAt.add(unreachableGrace))) return _expire(cancel: false);
        continue;
      }
      if (_stopped) return;
      switch (claim) {
        case PairWaiting():
          if (!_now().isBefore(expiresAt)) return _expire(cancel: true);
        case PairApproved(:final result, :final bundle):
          _stopped = true;
          _set(const PairFinishing());
          return _finish(result, bundle, code, eph, keys);
      }
    }
  }

  /// A cancellable wait, so a stopped pairing leaves no timer behind.
  Future<void> _sleep() {
    final c = _sleeping = Completer<void>();
    _timer = Timer(pollEvery, () {
      if (!c.isCompleted) c.complete();
    });
    return c.future;
  }

  void _wake() {
    _timer?.cancel();
    final c = _sleeping;
    if (c != null && !c.isCompleted) c.complete();
  }

  Future<void> _expire({required bool cancel}) async {
    _stopped = true;
    _set(const PairExpired());
    if (cancel) await _cancelOnServer();
  }

  Future<void> _finish(RedeemResult r, String sealed, PairCode code, SimpleKeyPair eph, DeviceKeys keys) async {
    try {
      final bundle = PairBundle.decode(await openPairBundle(eph: eph, secret: code.secret, sealed: b64urlDecode(sealed)));
      await verifyHandover(bundle,
          userId: r.userId, deviceId: r.deviceId, encPub: await keys.encPub(), signPub: await keys.signPub());
      final seeds = await keys.toStorage();
      _set(PairDone(PairedDevice(
        session: StoredSession(
          userId: r.userId,
          deviceId: r.deviceId,
          deviceName: deviceName,
          refreshToken: r.refreshToken,
          isAdmin: r.isAdmin,
          name: null,
          identitySeed: b64url(bundle.identitySeed),
          encSeed: seeds['encSeed']!,
          signSeed: seeds['signSeed']!,
        ),
        accessToken: r.accessToken,
        bundle: bundle,
      )));
    } on CryptoFailure {
      _set(const PairFailed(forgedBundleMessage));
    }
  }

  Future<void> _cancelOnServer() async {
    final s = _session;
    if (s == null) return;
    try {
      await api.pairCancel(s.sessionId, s.secret);
    } catch (_) {
      // Best effort: the session expires on its own.
    }
  }

  /// Stops polling and cancels the session (unless it already finished).
  Future<void> cancel() async {
    if (_state is PairDone || _state is PairFinishing) return;
    final wasActive = !_stopped;
    _stopped = true;
    _wake();
    if (wasActive) {
      _set(const PairCancelled());
      await _cancelOnServer();
    }
  }

  Future<void> dispose() async {
    _stopped = true;
    _wake();
    await _states.close();
  }
}
