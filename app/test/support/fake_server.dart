import 'dart:async';
// A stateful in-memory copy of the plan 1 API (server/src/routes/*.ts), served through
// package:http's MockClient. Access tokens are JWT-shaped but unsigned.
import 'dart:convert';
import 'dart:math';

import 'package:famchat/crypto/device_cert.dart';
import 'package:famchat/crypto/encoding.dart';
import 'package:famchat/crypto/reset.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class FakeUser {
  FakeUser(this.id, this.name, this.isAdmin, this.identityPub, {this.reviewer = false, bool? operator}) : operator = operator ?? isAdmin;
  final String id;
  String identityPub;
  String name;
  bool isAdmin;

  /// The operator (server OPERATOR_USER_ID): the only one who removes people or runs reviewers.
  final bool operator;
  bool deleted = false;
  bool former = false;

  /// In family 1 (removing someone from it clears this; their account stays).
  bool inFamily1 = true;

  /// Their role (`admin` or `member`) in each family besides family 1.
  final familyRoles = <int, String>{};

  /// A reviewer account: only other reviewers see it, and it sees only them.
  final bool reviewer;
  String? recoveryPub, recoverySig;
  Map<String, Object?>? adminProof;

  /// Directory reset records (server/src/lib/reset.ts resetOut).
  final resets = <Map<String, Object?>>[];
}

class FakeDevice {
  FakeDevice(this.id, this.userId, this.name, this.platform, this.cert, this.refresh, this.createdAt);
  final String id, userId, name, platform;
  final Map<String, String> cert;
  String? refresh, prevRefresh;
  DateTime? refreshedAt, revokedAt;
  final DateTime createdAt;
  late DateTime lastSeen = createdAt;
}

class FakeInvite {
  FakeInvite(this.name, this.admin, this.expiresAt, {this.userId, this.reset, this.reviewer = false, this.operator, this.familyId = 1});
  final bool? operator;
  final int familyId;
  final String name;
  final bool admin;
  DateTime expiresAt;
  String? usedBy;
  DateTime? usedAt;

  /// A reviewer invite: reusable (usedBy stays null) until [revoked].
  final bool reviewer;
  bool revoked = false;

  /// A reset invite: signs [userId] in again; [reset] is its directory record.
  final String? userId;
  final Map<String, Object?>? reset;
}

/// A pairing session (server/src/routes/pairing.ts).
class FakePairSession {
  FakePairSession(this.id, this.code, this.secret, this.deviceId, this.body, this.createdAt);
  final String id, code, secret, deviceId;

  /// ephPub, encPub, signPub, keysMac, deviceName, platform as posted.
  final Map<String, String> body;
  final DateTime createdAt;
  String? userId, certSig, bundle, approvedByDevice;
  DateTime? approvedAt, claimedAt, cancelledAt;

  /// Set when started from an offer: only this user may look it up or approve it.
  String? offerUserId;

  DateTime get expiresAt => createdAt.add(FakeServer.pairTtl);
}

/// A signed-in device's offer (reverse pairing).
class FakePairOffer {
  FakePairOffer(this.id, this.code, this.userId, this.createdAt);
  final String id, code, userId;
  final DateTime createdAt;
  String? sessionId;
  DateTime? cancelledAt;

  DateTime get expiresAt => createdAt.add(FakeServer.pairTtl);
}

class FakeServer {
  FakeServer({DateTime Function()? now}) : now = now ?? DateTime.now;

  /// The server's clock; tests may replace it.
  DateTime Function() now;

  final users = <String, FakeUser>{};
  final devices = <String, FakeDevice>{};
  final invites = <String, FakeInvite>{};

  /// The caller's families besides family 1 (`GET /families` rows: id, name, status, role, owner,
  /// memberCount). Tests edit it to play the operator approving or declining.
  final extraFamilies = <Map<String, Object?>>[];

  /// `GET /operator/families` rows (id, name, status, createdAt, creator: {id, name} | null,
  /// memberCount); approve and decline change `status`.
  final operatorRequests = <Map<String, Object?>>[];

  /// `GET /families` answers 403 while set (a refresh that fails).
  bool failFamilies = false;

  /// `POST /families/:id/join` waits for this to complete when set.
  Completer<void>? joinGate;

  /// Family 1's name (`PUT /families/1` renames it).
  String family1Name = 'Family';

  /// Every request as "METHOD /path -> status" (status 0 when the response was dropped).
  final log = <String>[];
  int refreshCalls = 0;

  /// The next refresh rotates the token server-side, then the response is lost.
  bool dropNextRefreshResponse = false;

  /// The next redeem succeeds server-side, then the response is lost.
  bool dropNextRedeemResponse = false;

  /// The next N refresh calls answer 500.
  int failNext5xx = 0;

  final pairSessions = <String, FakePairSession>{};
  final pairOffers = <String, FakePairOffer>{};

  /// Replaces fields of the next `GET /devices/pair/:code` answer (a lying server).
  Map<String, String>? tamperNextLookup;

  /// The next approved claim succeeds server-side, then the response is lost.
  bool dropNextClaimResponse = false;

  /// The next N claims answer 500.
  int failNextClaims = 0;

  static const pairTtl = Duration(minutes: 5);
  static const claimRetry = Duration(minutes: 10);

  /// Adds a user with [identityPub] (base64url) and no device, as if they joined elsewhere.
  String addUser(String name, {required String identityPub, bool admin = false, bool reviewer = false, bool? operator}) {
    final id = _id('U');
    users[id] = FakeUser(id, name, admin, identityPub, reviewer: reviewer, operator: operator);
    return id;
  }

  /// A reviewer invite (server/src/routes/admin.ts POST /admin/reviewer-invite); revokes earlier ones.
  String addReviewerInvite() {
    for (final i in invites.values.where((i) => i.reviewer)) {
      i.revoked = true;
    }
    final token = _token();
    invites[token] = FakeInvite('Reviewer', false, DateTime(9999), reviewer: true);
    return token;
  }

  FakePairSession? pairSessionByCode(String code) => pairSessions.values.where((x) => x.code == code).firstOrNull;

  /// What an approving device posts, without HTTP.
  void approvePairing(String code,
      {required String userId, required String certSig, required String bundle, String? approverDeviceId}) {
    final x = pairSessionByCode(code)!;
    x
      ..approvedByDevice = approverDeviceId
      ..userId = userId
      ..certSig = certSig
      ..bundle = bundle
      ..approvedAt = now();
  }

  int _epoch = 0;
  int _ids = 0;
  final _rand = Random(42);

  MockClient get client => MockClient(_handle);

  int get requestCount => log.length;

  String addInvite({String name = 'Mom', bool admin = false, bool? operator, int familyId = 1}) {
    final token = _token();
    invites[token] = FakeInvite(name, admin, now().add(const Duration(days: 7)), operator: operator, familyId: familyId);
    return token;
  }

  /// Adds a device for [userId] directly (like another phone the user already has).
  String addDevice(String userId, {String name = 'Laptop', String platform = 'linux'}) {
    final id = _id('D');
    devices[id] = FakeDevice(id, userId, name, platform, const {}, _token(), now());
    return id;
  }

  void revoke(String deviceId) {
    final d = devices[deviceId]!;
    d.revokedAt = now();
    d.refresh = d.prevRefresh = null;
    // Unclaimed pairings this device approved die with it (server/src/routes/devices.ts).
    for (final x in pairSessions.values) {
      if (x.approvedByDevice == deviceId && x.claimedAt == null) x.cancelledAt ??= now();
    }
  }

  /// Account deletion (server/src/lib/delete-account.ts), minus chats: renamed, devices revoked.
  void deleteUser(String userId) {
    final u = users[userId]!
      ..deleted = true
      ..name = 'Deleted user'
      ..isAdmin = false
      ..adminProof = null
      ..recoveryPub = null
      ..recoverySig = null;
    for (final d in devices.values.where((d) => d.userId == u.id && d.revokedAt == null).toList()) {
      revoke(d.id);
    }
  }

  /// Makes every access token issued so far invalid (like a server-side expiry).
  void expireAccessTokens() => _epoch++;

  List<FakeDevice> liveDevices(String userId) =>
      devices.values.where((d) => d.userId == userId && d.revokedAt == null).toList();

  String _id(String p) => '01J$p${(_ids++).toString().padLeft(22, '0')}';

  String _token() => base64Url.encode(List.generate(32, (_) => _rand.nextInt(256))).replaceAll('=', '');

  String _access(String sub, String dev, bool adm) {
    String enc(Object o) => base64Url.encode(utf8.encode(jsonEncode(o))).replaceAll('=', '');
    final exp = now().add(const Duration(minutes: 15)).millisecondsSinceEpoch ~/ 1000;
    return '${enc({'alg': 'none'})}.${enc({'sub': sub, 'dev': dev, 'adm': adm, 'exp': exp, 'e': _epoch})}.x';
  }

  Map<String, Object?>? _claims(http.Request r) {
    final h = r.headers['authorization'];
    if (h == null || !h.startsWith('Bearer ')) return null;
    try {
      final p = h.substring(7).split('.')[1];
      final j = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(p)))) as Map<String, Object?>;
      if (j['e'] != _epoch) return null;
      if ((j['exp'] as int) * 1000 <= now().millisecondsSinceEpoch) return null;
      final d = devices[j['dev']];
      if (d == null || d.revokedAt != null || d.userId != j['sub']) return null;
      return j;
    } catch (_) {
      return null;
    }
  }

  http.Response _json(Object body, [int status = 200]) =>
      http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

  http.Response _err(String code) => _json({'error': code}, switch (code) {
        'invalid_request' => 400,
        'unauthorized' => 401,
        'forbidden' => 403,
        'not_found' => 404,
        'invite_invalid' || 'pairing_invalid' => 410,
        'last_admin' || 'conflict' => 409,
        _ => 500,
      });

  Future<http.Response> _handle(http.Request r) async {
    final key = '${r.method} ${r.url.path}';
    try {
      final res = await _route(r);
      log.add('$key -> ${res.statusCode}');
      return res;
    } on http.ClientException {
      log.add('$key -> 0');
      rethrow;
    }
  }

  Map<String, Object?> _body(http.Request r) => jsonDecode(r.body) as Map<String, Object?>;

  Future<http.Response> _route(http.Request r) async {
    final path = r.url.path;
    if (r.method == 'POST' && path == '/api/auth/invite/redeem') return await _redeem(_body(r));
    if (r.method == 'POST' && path == '/api/auth/refresh') return _refresh(_body(r));
    if (r.method == 'POST' && path == '/api/devices/pair/start') return _pairStart(_body(r));
    if (r.method == 'POST' && path == '/api/devices/pair/claim') return await _pairClaim(_body(r));
    if (r.method == 'POST' && path == '/api/auth/recover/lookup') {
      final u = _recoveryUser(_body(r)['recoveryPub']);
      return u == null ? _err('unauthorized') : _json({'userId': u.id, 'identityPub': u.identityPub});
    }
    if (r.method == 'POST' && path == '/api/auth/recover') return await _recover(_body(r));
    if (r.method == 'POST' && path == '/api/devices/pair/cancel') {
      final x = _owned(_body(r));
      if (x == null) return _err('not_found');
      if (x.claimedAt == null) x.cancelledAt ??= now();
      return http.Response('', 204);
    }
    final c = _claims(r);
    if (c == null) return _err('unauthorized');
    final userId = c['sub'] as String, deviceId = c['dev'] as String;
    if (r.method == 'GET' && path == '/api/me') {
      final u = users[userId]!;
      return _json({
        'userId': userId,
        'deviceId': deviceId,
        'name': u.name,
        'isAdmin': u.isAdmin,
        'recoveryCodeSet': u.recoveryPub != null,
        'reviewer': u.reviewer,
        'operator': u.operator,
      });
    }
    if (r.method == 'GET' && path == '/api/users') {
      final side = users[userId]!.reviewer;
      return _json({
        'users': [
          for (final u in users.values.where((u) => u.reviewer == side))
            {
              'id': u.id,
              'name': u.name,
              'isAdmin': u.isAdmin,
              'identityPub': u.identityPub,
              'adminProof': u.adminProof,
              'families': [
                if (u.inFamily1) {'id': 1, 'role': u.isAdmin ? 'admin' : 'member', 'adminProof': u.adminProof},
                for (final f in u.familyRoles.entries) {'id': f.key, 'role': f.value, 'adminProof': null},
              ],
              'devices': [
                for (final d in devices.values.where((d) => d.userId == u.id))
                  {
                    'id': d.id,
                    'name': d.name,
                    'platform': d.platform,
                    'encPub': d.cert['encPub'] ?? '',
                    'signPub': d.cert['signPub'] ?? '',
                    'certSig': d.cert['certSig'] ?? '',
                    'revoked': d.revokedAt != null,
                  },
              ],
              'resets': u.resets,
              'deleted': u.deleted,
              'former': u.former,
            },
        ],
      });
    }
    if (r.method == 'DELETE' && path == '/api/me') {
      if (_body(r)['confirm'] != 'delete') return _err('invalid_request');
      final u = users[userId]!;
      final others = users.values.where((o) => o.id != userId && !o.deleted && !o.reviewer);
      if (u.isAdmin && others.isNotEmpty && !others.any((o) => o.isAdmin)) return _err('last_admin');
      deleteUser(userId);
      return http.Response('', 204);
    }
    final removeMatch = RegExp(r'^/api/admin/users/([^/]+)$').firstMatch(path);
    if (r.method == 'DELETE' && removeMatch != null) {
      if (!users[userId]!.operator) return _err('forbidden');
      final target = users[removeMatch[1]];
      if (removeMatch[1] == userId) return _err('invalid_request');
      if (target == null || target.deleted) return _err('not_found');
      deleteUser(target.id);
      return http.Response('', 204);
    }
    final adminUser = RegExp(r'^/api/admin/users/([^/]+)/(reset|admin)$').firstMatch(path);
    if (r.method == 'POST' && adminUser != null) {
      if (!users[userId]!.isAdmin) return _err('forbidden');
      final target = users[adminUser[1]];
      if (target == null) return _err('not_found');
      if (adminUser[2] == 'admin') {
        final sig = _body(r)['sig'];
        final by = users[userId]!;
        if (sig is! String ||
            !await verifyPromotion(
              signerPub: b64urlDecode(by.identityPub),
              userId: target.id,
              byUserId: by.id,
              sig: b64urlDecode(sig),
            )) {
          return _err('invalid_request');
        }
        target
          ..isAdmin = true
          ..adminProof = {'byUserId': by.id, 'signerPub': by.identityPub, 'sig': sig};
        return http.Response('', 204);
      }
      return await _reset(_body(r), users[userId]!, target);
    }
    // server/src/routes/families.ts: family 1 plus [extraFamilies] (the caller's rows) and each
    // user's [FakeUser.familyRoles].
    if (r.method == 'POST' && path == '/api/families/invite-lookup') {
      final me = users[userId]!;
      if (me.reviewer) return _err('forbidden');
      final inv = invites[_body(r)['inviteToken']];
      if (inv == null || inv.reviewer || inv.usedBy != null || inv.revoked || !inv.expiresAt.isAfter(now())) return _err('invite_invalid');
      final fid = inv.familyId;
      return _json({
        'familyId': fid,
        'familyName': fid == 1 ? family1Name : extraFamilies.firstWhere((f) => f['id'] == fid)['name'],
        'invitedName': inv.name,
        'alreadyMember': fid == 1 ? me.inFamily1 : me.familyRoles.containsKey(fid),
      });
    }
    final familyRoute = RegExp(r'^/api/families/(\d+)(/.*)?$').firstMatch(path);
    if (familyRoute != null && familyRoute[1] != null) {
      final res = await _family(r, users[userId]!, int.parse(familyRoute[1]!), familyRoute[2] ?? '');
      if (res != null) return res;
    }
    if (path == '/api/operator/families' || path.startsWith('/api/operator/families/')) {
      final u = users[userId]!;
      if (!u.operator || u.reviewer) return _err('forbidden');
      if (r.method == 'GET' && path == '/api/operator/families') {
        final status = r.url.queryParameters['status'] ?? 'pending';
        return _json({'families': [for (final f in operatorRequests) if (f['status'] == status) f]});
      }
      final decide = RegExp(r'^/api/operator/families/(\d+)/(approve|decline)$').firstMatch(path);
      if (r.method == 'POST' && decide != null) {
        final f = operatorRequests.where((f) => f['id'] == int.parse(decide[1]!)).firstOrNull;
        if (f == null) return _err('not_found');
        if (f['status'] != 'pending') return _err('conflict');
        f['status'] = decide[2] == 'approve' ? 'approved' : 'declined';
        return http.Response('', 204);
      }
    }
    if (r.method == 'GET' && path == '/api/families') {
      if (failFamilies) return _err('forbidden');
      final u = users[userId]!;
      return _json({
        'families': [
          {'id': 1, 'name': family1Name, 'status': 'approved', 'role': u.isAdmin ? 'admin' : 'member', 'owner': u.isAdmin, 'ownerId': u.isAdmin ? u.id : users.values.where((x) => x.isAdmin).firstOrNull?.id, 'memberCount': users.length, 'createdAt': 1},
          ...extraFamilies,
        ],
      });
    }
    if (r.method == 'POST' && path == '/api/families') {
      final name = _body(r)['name'];
      if (name is! String || name.trim().isEmpty || name.trim().length > 40) return _err('invalid_request');
      final family = {'id': 10 + extraFamilies.length, 'name': name.trim(), 'status': 'pending', 'role': 'admin', 'owner': true, 'ownerId': userId, 'memberCount': 1, 'createdAt': 2};
      extraFamilies.add(family);
      return _json({'family': family}, 201);
    }
    if (r.method == 'POST' && path == '/api/admin/recovery-key') {
      final u = users[userId]!;
      if (!u.isAdmin) return _err('forbidden');
      final b = _body(r);
      final ok = await verifyRecoveryKey(
        identityPub: b64urlDecode(u.identityPub),
        userId: u.id,
        recoveryPub: b64urlDecode(b['recoveryPub'] as String),
        sig: b64urlDecode(b['sig'] as String),
      );
      if (!ok) return _err('invalid_request');
      u
        ..recoveryPub = b['recoveryPub'] as String
        ..recoverySig = b['sig'] as String;
      return http.Response('', 204);
    }
    if (r.method == 'GET' && path == '/api/devices') {
      return _json({
        'devices': [
          for (final d in liveDevices(userId))
            {
              'id': d.id,
              'name': d.name,
              'platform': d.platform,
              'createdAt': d.createdAt.millisecondsSinceEpoch,
              'lastSeen': d.lastSeen.millisecondsSinceEpoch,
              'current': d.id == deviceId,
            },
        ],
      });
    }
    if (r.method == 'POST' && path == '/api/devices/pair/offer') {
      final id = _id('O');
      final o = pairOffers[id] = FakePairOffer(id, _code(), userId, now());
      return _json(
          {'offerId': id, 'code': o.code, 'expiresAt': o.expiresAt.millisecondsSinceEpoch, 'expiresIn': pairTtl.inMilliseconds},
          201);
    }
    final offer = RegExp(r'^/api/devices/pair/offer/([^/]+)(/cancel)?$').firstMatch(path);
    if (offer != null) {
      final o = pairOffers[offer[1]];
      if (o == null || o.userId != userId) return _err('not_found');
      final x = o.sessionId == null ? null : pairSessions[o.sessionId];
      if (r.method == 'POST' && offer[2] != null) {
        o.cancelledAt ??= now();
        if (x != null && x.approvedAt == null) x.cancelledAt ??= now();
        return http.Response('', 204);
      }
      if (o.cancelledAt != null) return _err('pairing_invalid');
      if (x == null) {
        return o.expiresAt.isAfter(now())
            ? _json({'status': 'waiting', 'expiresAt': o.expiresAt.millisecondsSinceEpoch})
            : _err('pairing_invalid');
      }
      if (x.cancelledAt != null) return _err('pairing_invalid');
      if (x.approvedAt != null) return _json({'status': 'approved'});
      if (!x.expiresAt.isAfter(now())) return _err('pairing_invalid');
      return _json({'status': 'ready', 'session': _sessionOut(x)});
    }
    final pair = RegExp(r'^/api/devices/pair/([^/]+)(/approve)?$').firstMatch(path);
    if (pair != null) {
      final x = pairSessions.values
          .where((x) =>
              x.code == pair[1]!.toUpperCase() &&
              x.approvedAt == null &&
              x.cancelledAt == null &&
              (x.offerUserId == null || x.offerUserId == userId) &&
              x.expiresAt.isAfter(now()))
          .firstOrNull;
      if (x == null) return _err('not_found');
      if (r.method == 'GET' && pair[2] == null) {
        return _json({'session': _sessionOut(x)});
      }
      if (r.method == 'POST' && pair[2] != null) {
        final b = _body(r);
        if (b['deviceId'] != x.deviceId) return _err('invalid_request');
        final cert = {
          'identityPub': users[userId]!.identityPub,
          'encPub': x.body['encPub']!,
          'signPub': x.body['signPub']!,
          'certSig': b['certSig'] as String,
        };
        try {
          if (!await verifyDeviceCert(DeviceCert.fromJson(cert))) return _err('invalid_request');
        } catch (_) {
          return _err('invalid_request');
        }
        approvePairing(x.code,
            userId: userId, certSig: cert['certSig']!, bundle: b['bundle'] as String, approverDeviceId: deviceId);
        return http.Response('', 204);
      }
    }
    if (r.method == 'DELETE' && path.startsWith('/api/devices/')) {
      final d = devices[path.substring('/api/devices/'.length)];
      if (d == null || d.userId != userId || d.revokedAt != null) return _err('not_found');
      revoke(d.id);
      return http.Response('', 204);
    }
    if (path == '/api/admin/reviewer-invite' || path == '/api/admin/reviewers') {
      final u = users[userId]!;
      if (!u.operator || u.reviewer) return _err('forbidden');
      String url(String token) => 'https://famchat.dev/join#review.$token';
      if (r.method == 'POST') return _json({'inviteToken': '', 'inviteUrl': url(addReviewerInvite()), 'createdAt': 0}, 201);
      if (r.method == 'DELETE') {
        for (final i in invites.values.where((i) => i.reviewer)) {
          i.revoked = true;
        }
        return http.Response('', 204);
      }
      final active = invites.entries.where((e) => e.value.reviewer && !e.value.revoked).lastOrNull;
      return _json({
        'invite': active == null ? null : {'inviteUrl': url(active.key), 'createdAt': 0},
        'users': [
          for (final x in users.values.where((x) => x.reviewer && !x.deleted))
            {'id': x.id, 'name': x.name, 'createdAt': 0, 'devices': liveDevices(x.id).length},
        ],
      });
    }
    if (r.method == 'POST' && path == '/api/admin/invites') {
      if (c['adm'] != true) return _err('forbidden');
      final name = (_body(r)['name'] as String?)?.trim() ?? '';
      if (name.isEmpty || name.length > 40) return _err('invalid_request');
      final token = addInvite(name: name);
      return _json({
        'inviteToken': token,
        'inviteUrl': 'https://famchat.dev/join#$token',
        'expiresAt': invites[token]!.expiresAt.millisecondsSinceEpoch,
      }, 201);
    }
    return _err('not_found');
  }

  /// `/families/:id/...` for [me]: rename, invites, promote, demote, leave and remove. Null when
  /// the route isn't one of these.
  Future<http.Response?> _family(http.Request r, FakeUser me, int id, String rest) async {
    final row = extraFamilies.where((f) => f['id'] == id).firstOrNull;
    if (id != 1 && row == null) return _err('not_found');
    final name = id == 1 ? family1Name : row!['name'] as String;
    final approved = id == 1 || row!['status'] == 'approved';
    final iAmAdmin = id == 1 ? me.isAdmin : row!['role'] == 'admin';
    final iAmOwner = id == 1 ? me.isAdmin : row!['owner'] == true;
    bool inIt(FakeUser u) => !u.deleted && !u.reviewer && (id == 1 ? u.inFamily1 : u.familyRoles.containsKey(id));
    bool inMine(FakeUser u) => id == 1 ? u.inFamily1 : u.familyRoles.containsKey(id);
    bool adminOf(FakeUser u) => id == 1 ? u.isAdmin : u.familyRoles[id] == 'admin';
    if (r.method == 'PUT' && rest.isEmpty) {
      final next = _body(r)['name'];
      if (next is! String || next.trim().isEmpty || next.trim().length > 40) return _err('invalid_request');
      if (approved ? !iAmAdmin : !iAmOwner) return _err('forbidden');
      if (id == 1) {
        family1Name = next.trim();
      } else {
        row!['name'] = next.trim();
      }
      return http.Response('', 204);
    }
    if (r.method == 'POST' && rest == '/join') {
      await joinGate?.future;
      final inv = invites[_body(r)['inviteToken']];
      if (inv == null || inv.reviewer || inv.familyId != id || inv.usedBy != null || inv.revoked || !inv.expiresAt.isAfter(now())) {
        return _err('invite_invalid');
      }
      if (inMine(me)) return _err('conflict');
      if (id == 1) {
        me.inFamily1 = true;
      } else {
        me.familyRoles[id] = 'member';
      }
      inv
        ..usedBy = me.id
        ..usedAt = now();
      return _json({
        'family': {'id': id, 'name': name, 'status': 'approved', 'role': 'member', 'owner': false, 'ownerId': null, 'memberCount': 2, 'createdAt': 1},
      });
    }
    if (r.method == 'POST' && rest == '/invites') {
      if (!approved || !iAmAdmin) return _err('forbidden');
      final invited = (_body(r)['name'] as String?)?.trim() ?? '';
      if (invited.isEmpty || invited.length > 40) return _err('invalid_request');
      final token = addInvite(name: invited, familyId: id);
      return _json({
        'inviteToken': token,
        'inviteUrl': 'https://famchat.dev/join#$token',
        'expiresAt': invites[token]!.expiresAt.millisecondsSinceEpoch,
      }, 201);
    }
    final admins = RegExp(r'^/admins/([^/]+)$').firstMatch(rest);
    if (r.method == 'POST' && admins != null) {
      if (!approved || !iAmAdmin) return _err('forbidden');
      final sig = _body(r)['sig'];
      if (sig is! String ||
          !await verifyPromotionV2(
            signerPub: b64urlDecode(me.identityPub),
            familyId: id,
            userId: admins[1]!,
            byUserId: me.id,
            sig: b64urlDecode(sig),
          )) {
        return _err('invalid_request');
      }
      final target = users[admins[1]];
      if (target == null || !inIt(target)) return _err('not_found');
      if (id == 1) {
        target
          ..isAdmin = true
          ..adminProof = {'byUserId': me.id, 'signerPub': me.identityPub, 'sig': sig};
      } else {
        target.familyRoles[id] = 'admin';
      }
      return http.Response('', 204);
    }
    if (r.method == 'DELETE' && admins != null) {
      if (!approved || !iAmOwner) return _err('forbidden');
      final target = users[admins[1]];
      if (target == null || target.id == me.id) return _err('forbidden');
      if (!inIt(target) || !adminOf(target)) return _err('not_found');
      if (id == 1) {
        target
          ..isAdmin = false
          ..adminProof = null;
      } else {
        target.familyRoles[id] = 'member';
      }
      return http.Response('', 204);
    }
    final members = RegExp(r'^/members/([^/]+)$').firstMatch(rest);
    if (r.method == 'DELETE' && members != null) {
      final target = users[members[1]];
      if (target == null) return _err('not_found');
      if (target.id == me.id) {
        final others = users.values.where((u) => u.id != me.id && inIt(u));
        if (iAmAdmin && others.isNotEmpty && !others.any(adminOf)) {
          return _json({'error': 'last_admin', 'familyId': id, 'familyName': name}, 409);
        }
        if (id != 1) extraFamilies.remove(row);
      } else {
        if (!approved || !iAmAdmin) return _err('forbidden');
        if (!inIt(target)) return _err('not_found');
        if (adminOf(target)) return _err('forbidden');
      }
      if (id == 1) {
        target
          ..inFamily1 = false
          ..isAdmin = false
          ..adminProof = null;
      } else {
        target.familyRoles.remove(id);
      }
      return http.Response('', 204);
    }
    return null;
  }

  /// A session as `GET /devices/pair/:code` and the offer poll show it (with [tamperNextLookup]).
  Map<String, Object?> _sessionOut(FakePairSession x) {
    final session = {
      'code': x.code,
      'deviceId': x.deviceId,
      ...x.body,
      'expiresAt': x.expiresAt.millisecondsSinceEpoch,
      ...?tamperNextLookup,
    };
    tamperNextLookup = null;
    return session;
  }

  String _code() {
    const alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
    return String.fromCharCodes(List.generate(4, (_) => alphabet.codeUnitAt(_rand.nextInt(32))));
  }

  http.Response _pairStart(Map<String, Object?> b) {
    const platforms = ['ios', 'android', 'macos', 'windows', 'linux', 'web'];
    final body = {
      for (final k in ['ephPub', 'encPub', 'signPub', 'keysMac', 'deviceName', 'platform'])
        if (b[k] is String) k: b[k] as String,
    };
    if (body.length != 6 || !platforms.contains(body['platform']) || body['deviceName']!.trim().isEmpty) {
      return _err('invalid_request');
    }
    FakePairOffer? offer;
    if (b['offer'] != null) {
      final code = (b['offer'] as String).toUpperCase();
      offer = pairOffers.values
          .where((o) => o.code == code && o.sessionId == null && o.cancelledAt == null && o.expiresAt.isAfter(now()))
          .firstOrNull;
      if (offer == null) return _err('not_found');
    }
    final id = _id('P');
    final x = FakePairSession(id, _code(), _token(), _id('D'), body, now());
    pairSessions[id] = x;
    if (offer != null) {
      offer.sessionId = id;
      x.offerUserId = offer.userId;
    }
    return _json({
      'sessionId': id,
      'code': x.code,
      'secret': x.secret,
      'deviceId': x.deviceId,
      'expiresAt': x.expiresAt.millisecondsSinceEpoch,
      'expiresIn': pairTtl.inMilliseconds,
    }, 201);
  }

  FakePairSession? _owned(Map<String, Object?> b) {
    final x = pairSessions[b['sessionId']];
    return x != null && x.secret == b['secret'] ? x : null;
  }

  Future<http.Response> _pairClaim(Map<String, Object?> b) async {
    if (failNextClaims > 0) {
      failNextClaims--;
      return _err('internal');
    }
    final x = _owned(b);
    if (x == null) return _err('not_found');
    final t = now();
    if (x.cancelledAt != null) return _err('pairing_invalid');
    if (x.approvedAt == null) {
      if (!x.expiresAt.isAfter(t)) return _err('pairing_invalid');
      return _json({'status': 'waiting'});
    }
    final refresh = _token();
    if (x.claimedAt == null) {
      if (!x.approvedAt!.add(claimRetry).isAfter(t)) return _err('pairing_invalid');
      final approver = x.approvedByDevice == null ? null : devices[x.approvedByDevice];
      if (approver != null && approver.revokedAt != null) return _err('pairing_invalid');
      // Against the user's current identity key (an admin reset since the approval fails it).
      final cert = {
        'identityPub': users[x.userId]!.identityPub,
        'encPub': x.body['encPub']!,
        'signPub': x.body['signPub']!,
        'certSig': x.certSig!,
      };
      if (!await verifyDeviceCert(DeviceCert.fromJson(cert))) return _err('pairing_invalid');
      x.claimedAt = t;
      devices[x.deviceId] = FakeDevice(x.deviceId, x.userId!, x.body['deviceName']!, x.body['platform']!, cert, refresh, t);
    } else {
      final d = devices[x.deviceId]!;
      if (!x.claimedAt!.add(claimRetry).isAfter(t) || d.revokedAt != null) return _err('pairing_invalid');
      d
        ..refresh = refresh
        ..prevRefresh = null;
    }
    if (dropNextClaimResponse) {
      dropNextClaimResponse = false;
      throw http.ClientException('connection reset');
    }
    final adm = users[x.userId]!.isAdmin;
    return _json({
      'status': 'approved',
      'userId': x.userId,
      'deviceId': x.deviceId,
      'isAdmin': adm,
      'accessToken': _access(x.userId!, x.deviceId, adm),
      'refreshToken': refresh,
      'bundle': x.bundle,
    });
  }

  FakeUser? _recoveryUser(Object? pub) =>
      pub is String ? users.values.where((u) => u.isAdmin && u.recoveryPub == pub).firstOrNull : null;

  void _revokeAll(String userId) {
    for (final d in liveDevices(userId)) {
      revoke(d.id);
    }
  }

  /// `POST /admin/users/:id/reset` (server/src/routes/admin.ts).
  Future<http.Response> _reset(Map<String, Object?> b, FakeUser admin, FakeUser target) async {
    if (admin.id == target.id) return _err('invalid_request');
    final st = ResetStatement(
      resetId: b['resetId'] as String,
      userId: target.id,
      signerUserId: admin.id,
      signerKind: 'admin',
      oldIdentityPub: b64urlDecode(b['oldIdentityPub'] as String),
      claimPub: b64urlDecode(b['claimPub'] as String),
      createdAt: b['createdAt'] as int,
    );
    if (!await verifyReset(st, signerPub: b64urlDecode(admin.identityPub), sig: b64urlDecode(b['sig'] as String))) {
      return _err('invalid_request');
    }
    if (b['oldIdentityPub'] != target.identityPub) return _json({'error': 'conflict'}, 409);
    final record = <String, Object?>{
      'id': st.resetId,
      'signerUserId': admin.id,
      'signerKind': 'admin',
      'signerPub': admin.identityPub,
      'recoverySig': null,
      'oldIdentityPub': b['oldIdentityPub'],
      'claimPub': b['claimPub'],
      'createdAt': st.createdAt,
      'sig': b['sig'],
      'newIdentityPub': null,
      'claimSig': null,
      'completedAt': null,
    };
    target.resets.add(record);
    _revokeAll(target.id);
    target
      ..recoveryPub = null
      ..recoverySig = null;
    for (final i in invites.values.where((i) => i.userId == target.id && i.usedBy == null)) {
      i.expiresAt = now();
    }
    final token = _token();
    invites[token] = FakeInvite(target.name, false, now().add(const Duration(days: 7)), userId: target.id, reset: record);
    return _json({
      'resetId': st.resetId,
      'inviteToken': token,
      'inviteUrl': 'https://famchat.dev/join#$token',
      'expiresAt': invites[token]!.expiresAt.millisecondsSinceEpoch,
    }, 201);
  }

  /// `POST /auth/recover` (server/src/routes/auth.ts).
  Future<http.Response> _recover(Map<String, Object?> b) async {
    final u = _recoveryUser(b['recoveryPub']);
    if (u == null) return _err('unauthorized');
    final cert = {for (final k in ['identityPub', 'encPub', 'signPub', 'certSig']) k: b[k] as String};
    final st = ResetStatement(
      resetId: b['resetId'] as String,
      userId: u.id,
      signerUserId: u.id,
      signerKind: 'recovery',
      oldIdentityPub: b64urlDecode(b['oldIdentityPub'] as String),
      claimPub: b64urlDecode(b['claimPub'] as String),
      createdAt: b['createdAt'] as int,
    );
    final ok = await verifyDeviceCert(DeviceCert.fromJson(cert)) &&
        await verifyReset(st, signerPub: b64urlDecode(u.recoveryPub!), sig: b64urlDecode(b['sig'] as String)) &&
        await verifyResetClaim(
          claimPub: st.claimPub,
          newIdentityPub: b64urlDecode(cert['identityPub']!),
          sig: b64urlDecode(b['claimSig'] as String),
        );
    if (!ok) return _err('invalid_request');
    if (b['oldIdentityPub'] != u.identityPub) return _json({'error': 'conflict'}, 409);
    u.resets.add({
      'id': st.resetId,
      'signerUserId': u.id,
      'signerKind': 'recovery',
      'signerPub': u.recoveryPub,
      'recoverySig': u.recoverySig,
      'oldIdentityPub': b['oldIdentityPub'],
      'claimPub': b['claimPub'],
      'createdAt': st.createdAt,
      'sig': b['sig'],
      'newIdentityPub': cert['identityPub'],
      'claimSig': b['claimSig'],
      'completedAt': now().millisecondsSinceEpoch,
    });
    _revokeAll(u.id);
    u
      ..identityPub = cert['identityPub']!
      ..recoveryPub = null
      ..recoverySig = null;
    final deviceId = _id('D'), refresh = _token();
    devices[deviceId] = FakeDevice(deviceId, u.id, b['deviceName'] as String, b['platform'] as String, cert, refresh, now());
    return _redeemed(u.id, deviceId, refresh);
  }

  Future<http.Response> _redeem(Map<String, Object?> b) async {
    final token = b['token'] as String;
    final deviceName = (b['deviceName'] as String).trim();
    const platforms = ['ios', 'android', 'macos', 'windows', 'linux', 'web'];
    if (deviceName.isEmpty || deviceName.length > 60 || !platforms.contains(b['platform'])) {
      return _err('invalid_request');
    }
    final cert = {for (final k in ['identityPub', 'encPub', 'signPub', 'certSig']) k: b[k] as String};
    try {
      if (!await verifyDeviceCert(DeviceCert.fromJson(cert))) return _err('invalid_request');
    } catch (_) {
      return _err('invalid_request');
    }
    final inv = invites[token];
    final t = now();
    final refresh = _token();
    final reset = inv?.reset;
    if (inv != null && reset != null && inv.usedBy == null && inv.expiresAt.isAfter(t)) {
      final claimSig = b['resetClaimSig'];
      if (claimSig is! String ||
          !await verifyResetClaim(
            claimPub: b64urlDecode(reset['claimPub'] as String),
            newIdentityPub: b64urlDecode(cert['identityPub']!),
            sig: b64urlDecode(claimSig),
          )) {
        return _err('invalid_request');
      }
      final u = users[inv.userId]!
        ..identityPub = cert['identityPub']!
        ..recoveryPub = null
        ..recoverySig = null;
      reset
        ..['newIdentityPub'] = cert['identityPub']
        ..['claimSig'] = claimSig
        ..['completedAt'] = t.millisecondsSinceEpoch;
      final deviceId = _id('D');
      devices[deviceId] = FakeDevice(deviceId, u.id, deviceName, b['platform'] as String, cert, refresh, t);
      inv
        ..usedBy = u.id
        ..usedAt = t;
      return _redeemed(u.id, deviceId, refresh);
    }
    if (inv != null && inv.reviewer) {
      if (inv.revoked) return _err('invite_invalid');
      final name = (b['name'] as String?)?.trim() ?? '';
      if (name.isEmpty || name.length > 40) return _err('invalid_request');
      final userId = _id('U'), deviceId = _id('D');
      users[userId] = FakeUser(userId, name, false, cert['identityPub']!, reviewer: true);
      devices[deviceId] = FakeDevice(deviceId, userId, deviceName, b['platform'] as String, cert, refresh, t);
      return _redeemed(userId, deviceId, refresh);
    }
    if (inv != null && inv.usedBy == null && inv.expiresAt.isAfter(t)) {
      final userId = _id('U'), deviceId = _id('D');
      users[userId] = FakeUser(userId, inv.name, inv.admin, cert['identityPub']!, operator: inv.operator);
      devices[deviceId] = FakeDevice(deviceId, userId, deviceName, b['platform'] as String, cert, refresh, t);
      inv
        ..usedBy = userId
        ..usedAt = t;
      return _redeemed(userId, deviceId, refresh);
    }
    // Same-keys retry within 10 minutes.
    if (inv != null && inv.usedBy != null && t.difference(inv.usedAt!) <= const Duration(minutes: 10)) {
      for (final d in liveDevices(inv.usedBy!)) {
        if (d.cert.toString() == cert.toString()) {
          d.refresh = refresh;
          return _redeemed(inv.usedBy!, d.id, refresh);
        }
      }
    }
    return _err('invite_invalid');
  }

  http.Response _redeemed(String userId, String deviceId, String refresh) {
    final adm = users[userId]!.isAdmin;
    if (dropNextRedeemResponse) {
      dropNextRedeemResponse = false;
      throw http.ClientException('connection reset');
    }
    return _json({
      'userId': userId,
      'deviceId': deviceId,
      'isAdmin': adm,
      'accessToken': _access(userId, deviceId, adm),
      'refreshToken': refresh,
    }, 201);
  }

  http.Response _refresh(Map<String, Object?> b) {
    refreshCalls++;
    if (failNext5xx > 0) {
      failNext5xx--;
      return _err('internal');
    }
    final old = b['refreshToken'] as String;
    final next = _token();
    final t = now();
    FakeDevice? d;
    for (final x in devices.values) {
      if (x.revokedAt == null && x.refresh == old) {
        d = x
          ..prevRefresh = old
          ..refresh = next
          ..refreshedAt = t;
        break;
      }
    }
    if (d == null) {
      for (final x in devices.values) {
        if (x.revokedAt == null &&
            x.prevRefresh == old &&
            t.difference(x.refreshedAt!) <= const Duration(seconds: 60)) {
          d = x..refresh = next;
          break;
        }
      }
    }
    if (d == null) {
      for (final x in devices.values) {
        if (x.revokedAt == null && x.prevRefresh == old) revoke(x.id);
      }
      return _err('unauthorized');
    }
    if (dropNextRefreshResponse) {
      dropNextRefreshResponse = false;
      throw http.ClientException('connection reset');
    }
    final u = users[d.userId]!;
    return _json({'accessToken': _access(u.id, d.id, u.isAdmin), 'refreshToken': next});
  }
}
