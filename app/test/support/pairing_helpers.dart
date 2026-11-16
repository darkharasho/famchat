// Both sides of pairing done by hand against FakeServer, so each side's real code can be tested
// against a counterpart the test controls.
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:famchat/api/api_client.dart';
import 'package:famchat/api/models.dart';
import 'package:famchat/api/token_manager.dart';
import 'package:famchat/crypto/device_cert.dart';
import 'package:famchat/crypto/encoding.dart';
import 'package:famchat/crypto/keys.dart';
import 'package:famchat/crypto/pairing.dart';
import 'package:famchat/pairing/bundle.dart';
import 'package:famchat/pairing/pair_code.dart';
import 'package:famchat/session/stored_session.dart';

import 'fake_server.dart';

final testBase = Uri.parse('https://famchat.dev');

/// An existing device: an [ApiClient] signed in to [server] as a new user whose keys the test holds.
class SignedInClient {
  SignedInClient(this.api, this.session, this.identity);
  final ApiClient api;
  final StoredSession session;
  final SimpleKeyPair identity;
  String get userId => session.userId;
}

Future<SignedInClient> signedInClient(FakeServer server, {String name = 'Alice'}) async {
  final identity = await newIdentityKey();
  final device = await DeviceKeys.generate();
  final cert = await signDeviceCert(identity: identity, device: device);
  final api = ApiClient(client: server.client, base: testBase);
  final r = await api.redeemInvite(token: server.addInvite(name: name), deviceName: 'Phone', platform: 'android', cert: cert);
  var refresh = r.refreshToken;
  api.tokens = TokenManager(
    refreshCall: api.refresh,
    readRefreshToken: () async => refresh,
    saveRefreshToken: (t) async => refresh = t,
    onRevoked: () async {},
    now: server.now,
    retryDelays: const [Duration.zero],
  )..setAccessToken(r.accessToken);
  final seeds = await device.toStorage();
  return SignedInClient(
    api,
    StoredSession(
      userId: r.userId,
      deviceId: r.deviceId,
      deviceName: 'Phone',
      refreshToken: r.refreshToken,
      isAdmin: r.isAdmin,
      name: name,
      identitySeed: b64url(await seedOf(identity)),
      encSeed: seeds['encSeed']!,
      signSeed: seeds['signSeed']!,
    ),
    identity,
  );
}

/// A new device's side, done by hand: a started session and what only that device knows.
class StartedPairing {
  StartedPairing(this.start, this.code, this.eph, this.ephPub, this.keys);
  final PairStartResult start;
  final PairCode code;
  final SimpleKeyPair eph;
  final Uint8List ephPub;
  final DeviceKeys keys;
  String get qr => PairQr(code, ephPub).encode();
}

Future<StartedPairing> startPairing(FakeServer server, {String deviceName = 'Laptop', String platform = 'linux'}) async {
  final api = ApiClient(client: server.client, base: testBase);
  final eph = await X25519().newKeyPair();
  final ephPub = await publicKeyOf(eph);
  final keys = await DeviceKeys.generate();
  final secret = newPairSecret();
  final encPub = await keys.encPub(), signPub = await keys.signPub();
  final s = await api.pairStart(
    ephPub: b64url(ephPub),
    encPub: b64url(encPub),
    signPub: b64url(signPub),
    keysMac: b64url(await pairKeysMac(
        secret: secret, ephPub: ephPub, encPub: encPub, signPub: signPub, deviceName: deviceName, platform: platform)),
    deviceName: deviceName,
    platform: platform,
  );
  return StartedPairing(s, PairCode(s.lookup, secret), eph, ephPub, keys);
}

/// An approving device's side, done by hand: approves the session shown as [code] for a user
/// created here with [identity], sealing [bundleFor]'s result with [secret] (default: the code's).
Future<({String userId, SimpleKeyPair identity, String approverDeviceId})> approveByHand(
  FakeServer server,
  PairCode code, {
  String name = 'Alice',
  String? secret,
  List<HandoverKey> keys = const [],
}) async {
  final identity = await newIdentityKey();
  final userId = server.addUser(name, identityPub: b64url(await publicKeyOf(identity)));
  final approverDeviceId = server.addDevice(userId, name: 'Phone', platform: 'android');
  final x = server.pairSessionByCode(code.lookup)!;
  final certSig = await signCertFor(
      identity: identity, encPub: b64urlDecode(x.body['encPub']!), signPub: b64urlDecode(x.body['signPub']!));
  final bundle = PairBundle(
    userId: userId,
    deviceId: x.deviceId,
    identitySeed: await seedOf(identity),
    certSig: certSig,
    keys: keys,
    trust: const [],
  );
  final sealed = await sealPairBundle(
    recipientEphPub: b64urlDecode(x.body['ephPub']!),
    secret: secret ?? code.secret,
    plaintext: bundle.encode(),
  );
  server.approvePairing(code.lookup,
      userId: userId, certSig: b64url(certSig), bundle: b64url(sealed), approverDeviceId: approverDeviceId);
  return (userId: userId, identity: identity, approverDeviceId: approverDeviceId);
}
