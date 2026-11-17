// An in-memory copy of the chat server and FamilyHub (server/src/routes/{users,chats,keys}.ts,
// server/src/hub.ts) with real device keys, so several test devices can talk to each other.
import 'dart:async';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:famchat/api/models.dart';
import 'package:famchat/chat/db/chat_db.dart';
import 'package:famchat/chat/directory.dart';
import 'package:famchat/chat/hub_link.dart';
import 'package:famchat/chat/wire.dart';
import 'package:famchat/crypto/device_cert.dart';
import 'package:famchat/crypto/encoding.dart';
import 'package:famchat/crypto/keys.dart';
import 'package:famchat/crypto/reset.dart';
import 'package:famchat/crypto/wrap.dart';
import 'package:famchat/media/media_api.dart';

class _User {
  _User(this.id, this.name, this.identity, this.identityPub);
  final String id;
  String name;
  SimpleKeyPair identity;
  Uint8List identityPub;
  bool isAdmin = false;
  bool deleted = false;
  bool former = false;
  AdminProofDto? adminProof;

  /// In family 1 (as everyone non-former is, unless removed from it); its role is [isAdmin].
  bool inFamily1 = true;

  /// Left out of `GET /users` altogether (a lie, or a glitch).
  bool omitted = false;

  /// Roles in families other than family 1.
  final otherFamilies = <FamilyRoleDto>[];
  final resets = <_Reset>[];
  String? avatarKey;
  Uint8List? avatar;
}

/// A signed reset (server/src/routes/admin.ts, auth.ts redeem).
class _Reset {
  _Reset(this.id, this.signerUserId, this.signerPub, this.oldIdentityPub, this.claim, this.claimPub, this.createdAt, this.sig);
  final String id, signerUserId;
  final Uint8List signerPub, oldIdentityPub, claimPub, sig;
  final SimpleKeyPair claim;
  final int createdAt;
  Uint8List? newIdentityPub, claimSig;

  ResetDto dto() => ResetDto(
        id: id,
        signerUserId: signerUserId,
        signerKind: 'admin',
        signerPub: b64url(signerPub),
        recoverySig: null,
        oldIdentityPub: b64url(oldIdentityPub),
        claimPub: b64url(claimPub),
        createdAt: createdAt,
        sig: b64url(sig),
        newIdentityPub: newIdentityPub == null ? null : b64url(newIdentityPub!),
        claimSig: claimSig == null ? null : b64url(claimSig!),
        completedAt: newIdentityPub == null ? null : createdAt + 1,
      );
}

class _Device {
  _Device(this.id, this.userId, this.keys, this.cert);
  final String id, userId;
  final DeviceKeys keys;
  DeviceCert cert;
  bool revoked = false;
}

class _Member {
  _Member(this.joinedSeq, this.joinedAt);
  final int joinedSeq, joinedAt;
  int lastReadSeq = 0;
  int? mutedUntil;
}

class _Chat {
  _Chat(this.id, this.kind, this.title, this.createdBy, this.directKey, this.createdAt);
  final String id, kind, createdBy;
  final String? title, directKey;
  final int createdAt;
  int currentEpoch = 1, lastSeq = 0;
  int? lastMessageAt;

  /// A group's family (the server's default, family 1, unless a test moves it); null for direct chats.
  int? familyId;
  final members = <String, _Member>{};
  final epochs = <int>{};
  final messages = <MessageDto>[];

  ChatDto dto([String? viewer]) => ChatDto(
        id: id,
        kind: kind,
        title: title,
        createdBy: createdBy,
        currentEpoch: currentEpoch,
        epochReady: epochs.contains(currentEpoch),
        lastSeq: lastSeq,
        lastMessageAt: lastMessageAt,
        createdAt: createdAt,
        mutedUntil: members[viewer]?.mutedUntil,
        familyId: familyId,
        members: [
          for (final e in members.entries)
            MemberDto(userId: e.key, joinedSeq: e.value.joinedSeq, lastReadSeq: e.value.lastReadSeq),
        ],
      );
}

/// One device of one user, wired to the backend.
/// Tests open one in-memory database per device on purpose.
void quietDrift() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

class TestDevice {
  TestDevice(this.backend, this.me, this.api, this.hub);
  final FakeChatBackend backend;
  final LocalIdentity me;
  final FakeChatApi api;
  final FakeHubLink hub;

  ChatDb? _db;
  ChatDb get db {
    quietDrift();
    return _db ??= ChatDb(NativeDatabase.memory())..myUserId = me.userId;
  }

  String get userId => me.userId;
  String get deviceId => me.deviceId;

  FakeMediaApi? _media;
  FakeMediaApi get media => _media ??= FakeMediaApi(backend, userId, deviceId);

  Future<void> dispose() async {
    await hub.stop();
    await _db?.close();
  }
}

class FakeChatBackend {
  int _ids = 0;
  int _clock = 1700000000000;
  final _users = <String, _User>{};
  final _devices = <String, _Device>{};
  final _chats = <String, _Chat>{};

  /// Ids of messages that were sent with `silent: true`.
  final silentIds = <String>{};

  /// The `mentions` of each send that had them, by message id.
  final sentMentions = <String, List<Object?>>{};
  final _wraps = <String, ChatKeyWrap>{};
  final _hubs = <String, FakeHubLink>{};

  /// Every REST call as "method path" (for asserting what a client did).
  final calls = <String>[];

  int now() => _clock += 10;

  String _id(String p) => '01J$p${(_ids++).toString().padLeft(22, '0')}';

  /// Marks [userId]'s account deleted in the directory (docs/protocol.md "Deleting an account").
  void markDeleted(String userId) => _users[userId]!.deleted = true;

  /// `GET /users` reports [userId] as a former chat partner: no shared family, so never an admin
  /// and no admin proof, as the server does.
  void markFormer(String userId, [bool former = true]) => _users[userId]!.former = former;

  /// Sets [userId]'s profile photo as the server would, telling everyone.
  String setAvatar(String userId, Uint8List? jpeg) {
    final u = _users[userId]!;
    u.avatar = jpeg;
    u.avatarKey = jpeg == null ? null : _id('A');
    _notify(_users.keys, {'type': 'profile', 'userId': userId});
    return u.avatarKey ?? '';
  }

  Uint8List? avatarOf(String userId) => _users[userId]!.avatar;

  /// What GET /preview answers, by URL (anything else: nothing to show).
  final previews = <String, FetchedPreview>{};

  /// Profile photo downloads, as "userId/key".
  final avatarDownloads = <String>[];

  Future<TestDevice> addUser(String name) async {
    final identity = await newIdentityKey();
    final u = _User(_id('U'), name, identity, await publicKeyOf(identity));
    _users[u.id] = u;
    return addDevice(u.id);
  }

  Future<TestDevice> addDevice(String userId) async {
    final u = _users[userId]!;
    final keys = await DeviceKeys.generate();
    final d = _Device(_id('D'), userId, keys, await signDeviceCert(identity: u.identity, device: keys));
    _devices[d.id] = d;
    final me = LocalIdentity(userId: userId, deviceId: d.id, keys: keys, identityPub: u.identityPub);
    final hub = FakeHubLink(this, d.id, userId);
    _hubs[d.id] = hub;
    return TestDevice(this, me, FakeChatApi(this, userId, d.id), hub);
  }

  /// A device added by pairing (server/src/routes/pairing.ts claim): its user and everyone sharing a
  /// chat with them get a `device` event unless [notify] is false.
  Future<TestDevice> pairDevice(String userId, {bool notify = true}) async {
    final d = await addDevice(userId);
    if (notify) _notify(_sharing(userId), {'type': 'device', 'userId': userId, 'deviceId': d.deviceId});
    return d;
  }

  /// `DELETE /devices/:id` (server/src/routes/devices.ts): revokes, closes its socket, moves every chat
  /// of its user to a new epoch, and sends `chat` and `device` events.
  void revoke(String deviceId) {
    final d = _devices[deviceId]!;
    if (d.revoked) return;
    d.revoked = true;
    _hubs[deviceId]?.drop();
    for (final c in _chats.values.where((c) => c.members.containsKey(d.userId))) {
      c.currentEpoch++;
      _notify(c.members.keys, {'type': 'chat', 'chatId': c.id});
    }
    _notify(_sharing(d.userId), {'type': 'device', 'userId': d.userId, 'deviceId': deviceId, 'revoked': true});
  }

  /// The user's identity key pair (a device that holds it, for pairing tests).
  SimpleKeyPair identityOf(String userId) => _users[userId]!.identity;

  /// Like an admin reset: a new identity key; the user's old devices are revoked.
  Future<TestDevice> resetUser(String userId) async {
    final u = _users[userId]!;
    u.identity = await newIdentityKey();
    u.identityPub = await publicKeyOf(u.identity);
    for (final d in _devices.values.where((d) => d.userId == userId)) {
      d.revoked = true;
    }
    return addDevice(userId);
  }

  /// The server marks [userId] admin (or not) with no signed promotion (the bootstrap admin, or a lie).
  void setAdmin(String userId, [bool admin = true]) => _users[userId]!.isAdmin = admin;

  /// The server lists [userId] in another family (a real one, or a lie).
  void addFamilyRole(String userId, FamilyRoleDto role) => _users[userId]!.otherFamilies.add(role);

  /// The server stops listing [userId] in [familyId] (they left, or were removed).
  void removeFamilyRole(String userId, int familyId) {
    final u = _users[userId]!;
    if (familyId == 1) u.inFamily1 = false;
    u.otherFamilies.removeWhere((f) => f.id == familyId);
  }

  /// Moves group [chatId] to [familyId] and tells its members (`chat`), as a test stand-in.
  void setChatFamily(String chatId, int familyId) {
    final c = _chats[chatId]!..familyId = familyId;
    _notify(c.members.keys, {'type': 'chat', 'chatId': chatId});
  }

  /// Sends `{type: "family", familyId}` to [userIds], as the server does when a family changes.
  void familyEvent(Iterable<String> userIds, int familyId) => _notify(userIds, {'type': 'family', 'familyId': familyId});

  /// The server lists [userId] in family 1 again.
  void addToFamily1(String userId) => _users[userId]!.inFamily1 = true;

  /// `GET /users` leaves [userId] out (or lists them again).
  void omitFromUsers(String userId, [bool omit = true]) => _users[userId]!.omitted = omit;

  /// `POST /admin/users/:id/admin` signed by [by]'s identity key.
  Future<void> promote(String userId, {required String by}) async {
    final admin = _users[by]!;
    _users[userId]!
      ..isAdmin = true
      ..adminProof = AdminProofDto(
        byUserId: by,
        signerPub: b64url(admin.identityPub),
        sig: b64url(await signPromotion(admin.identity, userId: userId, byUserId: by)),
      );
  }

  /// `POST /admin/users/:id/reset` signed by [by]'s identity key: [userId]'s devices are revoked
  /// (chats rotate), everyone gets a `reset` event. Returns the reset id.
  Future<String> adminReset(String userId, {required String by}) async {
    final u = _users[userId]!, admin = _users[by]!;
    final claim = await newIdentityKey();
    final id = _id('R');
    final at = now();
    final st = ResetStatement(
      resetId: id,
      userId: userId,
      signerUserId: by,
      signerKind: 'admin',
      oldIdentityPub: u.identityPub,
      claimPub: await publicKeyOf(claim),
      createdAt: at,
    );
    u.resets.add(_Reset(id, by, admin.identityPub, u.identityPub, claim, st.claimPub, at, await signReset(st, admin.identity)));
    for (final d in _devices.values.where((d) => d.userId == userId && !d.revoked).toList()) {
      revoke(d.id);
    }
    _notify(_users.keys, {'type': 'reset', 'userId': userId, 'resetId': id});
    return id;
  }

  /// Redeeming the reset link: a new identity key (claimed with the link's claim key, or with some
  /// other key if [badClaim]) and a first device; `device` and `reset` events.
  Future<TestDevice> claimReset(String userId, String resetId, {bool badClaim = false}) async {
    final u = _users[userId]!;
    final r = u.resets.firstWhere((r) => r.id == resetId);
    u.identity = await newIdentityKey();
    u.identityPub = await publicKeyOf(u.identity);
    r.newIdentityPub = u.identityPub;
    r.claimSig = await signResetClaim(badClaim ? await newIdentityKey() : r.claim, newIdentityPub: u.identityPub);
    final d = await addDevice(userId);
    _notify(_sharing(userId), {'type': 'device', 'userId': userId, 'deviceId': d.deviceId});
    _notify(_users.keys, {'type': 'reset', 'userId': userId, 'resetId': resetId});
    return d;
  }

  /// Gives [deviceId] a certificate signed by some other identity (a server-forged device).
  Future<void> forgeCert(String deviceId) async {
    final d = _devices[deviceId]!;
    d.cert = await signDeviceCert(identity: await newIdentityKey(), device: d.keys);
  }

  /// Stores a wrap without any checks (a malicious server).
  void injectWrap(ChatKeyWrap w) => _wraps['${w.chatId}|${w.epoch}|${w.recipientDeviceId}'] = w;

  void deleteWrap(String chatId, int epoch, String deviceId) => _wraps.remove('$chatId|$epoch|$deviceId');

  /// Stores a message row as-is and returns it (a malicious server, or a peer that sent earlier).
  MessageDto injectMessage(String chatId, {required String id, required String senderUserId, required String senderDeviceId, required Map<String, Object?> envelope, bool fanOut = true}) {
    final c = _chats[chatId]!;
    final m = MessageDto(
      chatId: chatId,
      seq: ++c.lastSeq,
      id: id,
      senderUserId: senderUserId,
      senderDeviceId: senderDeviceId,
      envelope: envelope,
      createdAt: now(),
    );
    c.messages.add(m);
    c.lastMessageAt = m.createdAt;
    if (fanOut) {
      for (final u in c.members.keys) {
        _toUser(u, {'type': 'msg', 'message': _msgJson(m)});
      }
    }
    return m;
  }

  // --- media (server/src/routes/media.ts) ---

  final _media = <String, _Blob>{};

  /// Stored media keys.
  Iterable<String> get mediaKeys => _media.keys;
  Uint8List? mediaBlob(String key) => _media[key]?.bytes;

  /// Replaces a stored blob (a malicious or broken server).
  void tamperMedia(String key, Uint8List bytes) => _media[key]!.bytes = bytes;

  /// Expires media like quota eviction: members of each blob's chat get `media_expired`.
  void expireMedia(List<String> keys) {
    final byChat = <String, List<String>>{};
    for (final k in keys) {
      final m = _media[k]!..expired = true;
      (byChat[m.chatId] ??= []).add(k);
    }
    for (final e in byChat.entries) {
      _notify(_chats[e.key]!.members.keys, {'type': 'media_expired', 'chatId': e.key, 'keys': e.value});
    }
  }

  ChatDto chatDto(String id) => _chats[id]!.dto();
  List<MessageDto> storedMessages(String chatId) => List.of(_chats[chatId]!.messages);
  bool hasWrap(String chatId, int epoch, String deviceId) => _wraps.containsKey('$chatId|$epoch|$deviceId');
  int wrapCount() => _wraps.length;

  // --- helpers mirroring the server ---

  /// A usable wrap's wrapper is a live device of a current member (server/src/routes/keys.ts).
  bool _wrapperIsMember(ChatKeyWrap w) {
    final wrapper = _devices[w.wrapperDeviceId];
    return wrapper != null && !wrapper.revoked && (_chats[w.chatId]?.members.containsKey(wrapper.userId) ?? false);
  }

  /// The user and everyone sharing a chat with them (server/src/lib/family.ts).
  Set<String> _sharing(String userId) => {
        userId,
        for (final c in _chats.values)
          if (c.members.containsKey(userId)) ...c.members.keys,
      };

  bool _hasUsableWrap(String chatId, int epoch, String deviceId) {
    final w = _wraps['$chatId|$epoch|$deviceId'];
    return w != null && _wrapperIsMember(w);
  }

  Never _err(String code) => throw ApiException(
        switch (code) {
          'invalid_request' => 400,
          'forbidden' => 403,
          'not_found' => 404,
          'wraps_mismatch' || 'epoch_exists' || 'stale_epoch' => 409,
          _ => 500,
        },
        code,
      );

  List<String> _liveDevices(Iterable<String> userIds) =>
      [for (final d in _devices.values) if (!d.revoked && userIds.contains(d.userId)) d.id];

  void _coverage(List<ChatKeyWrap> wraps, String chatId, int epoch, String wrapper, List<String> deviceIds) {
    final want = deviceIds.toSet(), seen = <String>{};
    for (final w in wraps) {
      if (w.chatId != chatId || w.wrapperDeviceId != wrapper) _err('wraps_mismatch');
      if (w.epoch != epoch) continue;
      if (!want.contains(w.recipientDeviceId) || !seen.add(w.recipientDeviceId)) _err('wraps_mismatch');
    }
    if (seen.length != want.length) _err('wraps_mismatch');
  }

  void _store(List<ChatKeyWrap> wraps) {
    for (final w in wraps) {
      _wraps.putIfAbsent('${w.chatId}|${w.epoch}|${w.recipientDeviceId}', () => w);
    }
  }

  _Chat _memberChat(String chatId, String userId) {
    final c = _chats[chatId];
    if (c == null || !c.members.containsKey(userId)) _err('not_found');
    return c;
  }

  Map<String, Object?> _msgJson(MessageDto m) => {
        'chatId': m.chatId,
        'seq': m.seq,
        'id': m.id,
        'senderUserId': m.senderUserId,
        'senderDeviceId': m.senderDeviceId,
        'envelope': m.envelope,
        'createdAt': m.createdAt,
      };

  Iterable<FakeHubLink> _socketsOf(String userId) => _hubs.values.where((h) => h.connected && h.userId == userId);

  void _toUser(String userId, Map<String, Object?> event, {FakeHubLink? except}) {
    for (final h in _socketsOf(userId)) {
      if (h != except) h._deliver(event);
    }
  }

  void _notify(Iterable<String> userIds, Map<String, Object?> event) {
    for (final u in userIds.toSet()) {
      _toUser(u, event);
    }
  }

  Set<String> get _online => {for (final h in _hubs.values) if (h.connected) h.userId};

  // --- hub ---

  void _connected(FakeHubLink h) {
    final wasOnline = _socketsOf(h.userId).any((x) => x != h);
    h._deliver({'type': 'hello', 'online': _online.toList()});
    if (!wasOnline) {
      for (final o in _hubs.values) {
        if (o != h && o.connected) o._deliver({'type': 'presence', 'userId': h.userId, 'online': true});
      }
    }
  }

  void _disconnected(FakeHubLink h) {
    if (_socketsOf(h.userId).isEmpty) {
      for (final o in _hubs.values) {
        if (o.connected) o._deliver({'type': 'presence', 'userId': h.userId, 'online': false});
      }
    }
  }

  void _hubFrame(FakeHubLink h, Map<String, Object?> m) {
    switch (m['type']) {
      case 'send':
        final id = m['id'] as String, chatId = m['chatId'] as String;
        final env = m['envelope'] as Map<String, Object?>;
        final prior = _chats.values.expand((c) => c.messages).where((x) => x.id == id).firstOrNull;
        if (prior != null) {
          if (prior.chatId == chatId && prior.senderDeviceId == h.deviceId) {
            h._deliver({'type': 'ack', 'id': id, 'seq': prior.seq, 'createdAt': prior.createdAt});
          } else {
            h._deliver({'type': 'error', 'id': id, 'error': 'conflict'});
          }
          return;
        }
        final c = _chats[chatId];
        if (c == null || !c.members.containsKey(h.userId)) {
          return h._deliver({'type': 'error', 'id': id, 'error': 'not_member'});
        }
        if (c.kind == 'direct' && c.members.keys.any((u) => u != h.userId && _users[u]!.former)) {
          return h._deliver({'type': 'error', 'id': id, 'error': 'no_shared_family'});
        }
        if (env['epoch'] != c.currentEpoch || !c.epochs.contains(c.currentEpoch)) {
          return h._deliver({'type': 'error', 'id': id, 'error': 'stale_epoch'});
        }
        final msg = MessageDto(
          chatId: chatId,
          seq: ++c.lastSeq,
          id: id,
          senderUserId: h.userId,
          senderDeviceId: h.deviceId,
          envelope: env,
          createdAt: now(),
        );
        c.messages.add(msg);
        c.lastMessageAt = msg.createdAt;
        if (m['silent'] == true) silentIds.add(id);
        if (m['mentions'] is List) sentMentions[id] = m['mentions'] as List<Object?>;
        if (h.dropNextAck) {
          h.dropNextAck = false;
          h.drop();
        } else {
          h._deliver({'type': 'ack', 'id': id, 'seq': msg.seq, 'createdAt': msg.createdAt});
        }
        if (h.holdFanOut) return;
        for (final u in c.members.keys) {
          _toUser(u, {'type': 'msg', 'message': _msgJson(msg)}, except: h);
        }
      case 'typing':
        final c = _chats[m['chatId']];
        if (c == null || !c.members.containsKey(h.userId)) return;
        for (final u in c.members.keys) {
          if (u != h.userId) _toUser(u, {'type': 'typing', 'chatId': c.id, 'userId': h.userId});
        }
      case 'read':
        final c = _chats[m['chatId']];
        final mem = c?.members[h.userId];
        if (c == null || mem == null) return;
        final seq = (m['seq'] as int) < c.lastSeq ? m['seq'] as int : c.lastSeq;
        if (seq <= mem.lastReadSeq) return;
        mem.lastReadSeq = seq;
        _notify(c.members.keys, {'type': 'read', 'chatId': c.id, 'userId': h.userId, 'seq': seq});
    }
  }
}

/// [ChatApi] for one device, enforcing the server's rules.
class FakeChatApi implements ChatApi {
  FakeChatApi(this.b, this.userId, this.deviceId);
  final FakeChatBackend b;
  final String userId, deviceId;

  /// When set, the next call throws this instead of running.
  Object? failNext;

  Future<T> _run<T>(String call, T Function() f) async {
    await Future<void>.delayed(Duration.zero);
    b.calls.add(call);
    final fail = failNext;
    if (fail != null) {
      failNext = null;
      throw fail;
    }
    return f();
  }

  @override
  Future<String> setAvatar(Uint8List jpeg) => _run('PUT /me/avatar', () => b.setAvatar(userId, jpeg));

  @override
  Future<FetchedPreview?> preview(String url) => _run('GET /preview', () => b.previews[url]);

  @override
  Future<void> removeAvatar() => _run('DELETE /me/avatar', () => b.setAvatar(userId, null));

  @override
  Future<void> setName(String name) => _run('PUT /me/name', () {
        b._users[userId]!.name = name.trim();
        b._notify(b._users.keys, {'type': 'profile', 'userId': userId});
      });

  @override
  Future<Uint8List> avatar(String userId, String key) => _run('GET /users/$userId/avatar', () {
        final u = b._users[userId];
        if (u == null || u.avatarKey != key || u.avatar == null) throw ApiException(404, 'not_found');
        b.avatarDownloads.add('$userId/$key');
        return u.avatar!;
      });

  @override
  Future<List<UserDto>> users() => _run('GET /users', () => [
        for (final u in b._users.values)
          if (!u.omitted)
          UserDto(
            id: u.id,
            name: u.name,
            isAdmin: u.isAdmin && !u.former && u.inFamily1,
            former: u.former,
            resets: [for (final r in u.resets) r.dto()],
            adminProof: u.former ? null : u.adminProof,
            families: u.former
                ? const []
                : [if (u.inFamily1) FamilyRoleDto(id: 1, admin: u.isAdmin, adminProof: u.adminProof), ...u.otherFamilies],
            deleted: u.deleted,
            avatarKey: u.avatarKey,
            identityPub: b64url(u.identityPub),
            devices: [
              for (final d in b._devices.values.where((d) => d.userId == u.id))
                DeviceDto(
                  id: d.id,
                  userId: u.id,
                  name: 'Phone',
                  platform: 'android',
                  encPub: b64url(d.cert.encPub),
                  signPub: b64url(d.cert.signPub),
                  certSig: b64url(d.cert.certSig),
                  revoked: d.revoked,
                ),
            ],
          ),
      ]);

  @override
  Future<List<ChatDto>> chats() => _run('GET /chats', () => [
        for (final c in b._chats.values)
          if (c.members.containsKey(userId)) c.dto(userId),
      ]);

  @override
  Future<ChatDto> chat(String id) => _run('GET /chats/$id', () => b._memberChat(id, userId).dto(userId));

  @override
  Future<({ChatDto chat, bool created})> createChat({
    required String id,
    required String kind,
    String? title,
    required List<String> userIds,
    required List<ChatKeyWrap> wraps,
  }) =>
      _run('POST /chats', () {
        final existing = b._chats[id];
        if (existing != null) {
          if (existing.createdBy != userId) b._err('invalid_request');
          return (chat: existing.dto(), created: false);
        }
        String? directKey;
        if (kind == 'direct') {
          if (userIds.length != 1 || userIds.single == userId) b._err('invalid_request');
          directKey = ([userId, userIds.single]..sort()).join(':');
          final dup = b._chats.values.where((c) => c.directKey == directKey).firstOrNull;
          if (dup != null) return (chat: dup.dto(), created: false);
        } else if (title == null || title.trim().isEmpty || userIds.contains(userId)) {
          // No others is a chat with only yourself ("Note to self").
          b._err('invalid_request');
        }
        if (!userIds.every(b._users.containsKey)) b._err('invalid_request');
        final members = [userId, ...userIds.toSet()];
        b._coverage(wraps, id, 1, deviceId, b._liveDevices(members));
        final t = b.now();
        final c = _Chat(id, kind, kind == 'group' ? title!.trim() : null, userId, directKey, t)
          ..epochs.add(1)
          ..familyId = kind == 'group' ? 1 : null;
        for (final u in members) {
          c.members[u] = _Member(0, t);
        }
        b._chats[id] = c;
        b._store(wraps);
        b._notify(members, {'type': 'chat', 'chatId': id});
        return (chat: c.dto(), created: true);
      });

  @override
  Future<ChatDto> addMembers(String chatId, List<String> userIds, List<ChatKeyWrap> wraps) =>
      _run('POST /chats/$chatId/members', () {
        final c = b._memberChat(chatId, userId);
        if (c.kind != 'group' || userIds.isEmpty || userIds.any(c.members.containsKey)) b._err('invalid_request');
        if (!c.epochs.contains(c.currentEpoch)) b._err('stale_epoch');
        final newDevices = b._liveDevices(userIds);
        b._coverage(wraps, chatId, c.currentEpoch, deviceId, newDevices);
        if (wraps.any((w) => !c.epochs.contains(w.epoch) || !newDevices.contains(w.recipientDeviceId))) {
          b._err('wraps_mismatch');
        }
        for (final u in userIds) {
          c.members[u] = _Member(c.lastSeq, b.now());
        }
        b._store(wraps);
        b._notify(c.members.keys, {'type': 'chat', 'chatId': chatId});
        return c.dto();
      });

  @override
  Future<void> removeMember(String chatId, String target) => _run('DELETE /chats/$chatId/members/$target', () {
        final c = b._memberChat(chatId, userId);
        if (c.kind != 'group') b._err('invalid_request');
        if (target != userId && c.createdBy != userId) b._err('forbidden');
        if (!c.members.containsKey(target)) b._err('not_found');
        c.members.remove(target);
        c.currentEpoch++;
        b._notify([target], {'type': 'removed', 'chatId': chatId});
        b._notify(c.members.keys, {'type': 'chat', 'chatId': chatId});
      });

  @override
  Future<void> muteChat(String chatId, int? until) => _run('PUT /chats/$chatId/mute', () {
        b._memberChat(chatId, userId).members[userId]!.mutedUntil = until;
        b._notify([userId], {'type': 'chat', 'chatId': chatId});
      });

  @override
  Future<void> createEpoch(String chatId, int epoch, List<ChatKeyWrap> wraps) => _run('POST /chats/$chatId/epochs', () {
        final c = b._memberChat(chatId, userId);
        if (epoch != c.currentEpoch) b._err('stale_epoch');
        if (c.epochs.contains(epoch)) b._err('epoch_exists');
        b._coverage(wraps, chatId, epoch, deviceId, b._liveDevices(c.members.keys));
        c.epochs.add(epoch);
        b._store(wraps);
        b._notify(c.members.keys, {'type': 'keys', 'chatId': chatId, 'epoch': epoch});
      });

  @override
  Future<List<MessageDto>> messages(String chatId, {int? after, int? before, int limit = 100}) =>
      _run('GET /chats/$chatId/messages', () {
        final c = b._memberChat(chatId, userId);
        if (before != null) {
          final rows = c.messages.where((m) => m.seq < before).toList();
          return rows.sublist(rows.length > limit ? rows.length - limit : 0);
        }
        return c.messages.where((m) => m.seq > (after ?? 0)).take(limit).toList();
      });

  @override
  Future<List<ChatKeyWrap>> wraps({String? chatId}) => _run('GET /keys/wraps', () => [
        for (final w in b._wraps.values)
          if (w.recipientDeviceId == deviceId &&
              (chatId == null || w.chatId == chatId) &&
              (b._chats[w.chatId]?.members.containsKey(userId) ?? false))
            w,
      ]);

  @override
  Future<int> putWraps(List<ChatKeyWrap> wraps) => _run('PUT /keys/wraps', () {
        if (wraps.isEmpty) b._err('invalid_request');
        for (final w in wraps) {
          final c = b._chats[w.chatId];
          if (c == null || !c.members.containsKey(userId) || w.wrapperDeviceId != deviceId) b._err('invalid_request');
        }
        var added = 0;
        for (final w in wraps) {
          final c = b._chats[w.chatId]!;
          if (!c.epochs.contains(w.epoch) || !b._liveDevices(c.members.keys).contains(w.recipientDeviceId)) continue;
          final k = '${w.chatId}|${w.epoch}|${w.recipientDeviceId}';
          final old = b._wraps[k];
          if (old != null && b._wrapperIsMember(old)) continue;
          b._wraps[k] = w;
          added++;
          b._notify([b._devices[w.recipientDeviceId]!.userId], {'type': 'keys', 'chatId': w.chatId});
        }
        return added;
      });

  @override
  Future<List<MissingWrap>> missingWraps() => _run('GET /keys/missing', () => [
        for (final w in b._wraps.values.where((w) => w.recipientDeviceId == deviceId))
          if (b._chats[w.chatId]?.members.containsKey(userId) ?? false)
            for (final d in b._liveDevices(b._chats[w.chatId]!.members.keys))
              if (b._chats[w.chatId]!.epochs.contains(w.epoch) && !b._hasUsableWrap(w.chatId, w.epoch, d))
                MissingWrap(chatId: w.chatId, epoch: w.epoch, deviceId: d),
      ]);

  @override
  Future<String> wsTicket() => _run('POST /ws/ticket', () => 'ticket-$deviceId');
}

class _Blob {
  _Blob(this.bytes, this.chatId, this.deviceId);
  Uint8List bytes;
  final String chatId, deviceId;
  bool expired = false;
}

/// [MediaApi] for one device, with the server's rules (caps, membership, idempotent re-upload).
class FakeMediaApi implements MediaApi {
  FakeMediaApi(this.b, this.userId, this.deviceId);
  final FakeChatBackend b;
  final String userId, deviceId;

  /// The next [failUploads] uploads throw [failWith] before storing anything.
  int failUploads = 0;
  Object failWith = const NetworkException('offline');

  /// While set, uploads wait for it (after reporting half their progress).
  Completer<void>? hold;

  /// Keys uploaded / downloaded, in order.
  final uploads = <String>[];
  final downloads = <String>[];

  @override
  Future<void> upload({
    required String key,
    required String chatId,
    required String kind,
    String? messageId,
    required Uint8List bytes,
    void Function(int sent, int total)? onProgress,
  }) async {
    await Future<void>.delayed(Duration.zero);
    if (failUploads > 0) {
      failUploads--;
      throw failWith;
    }
    final limit = mediaKindLimits[kind];
    if (limit == null || bytes.isEmpty) b._err('invalid_request');
    b._memberChat(chatId, userId);
    if (bytes.length > limit) throw const ApiException(413, 'too_large');
    onProgress?.call(bytes.length ~/ 2, bytes.length);
    final h = hold;
    if (h != null) await h.future;
    final prior = b._media[key];
    if (prior != null) {
      if (prior.deviceId == deviceId && prior.chatId == chatId && prior.bytes.length == bytes.length && !prior.expired) return;
      throw const ApiException(409, 'conflict');
    }
    b._media[key] = _Blob(Uint8List.fromList(bytes), chatId, deviceId);
    uploads.add(key);
    onProgress?.call(bytes.length, bytes.length);
  }

  @override
  Future<Uint8List> download(String key) async {
    await Future<void>.delayed(Duration.zero);
    final m = b._media[key];
    if (m == null) b._err('not_found');
    b._memberChat(m.chatId, userId);
    if (m.expired) throw const ApiException(410, 'media_expired');
    downloads.add(key);
    return Uint8List.fromList(m.bytes);
  }

  @override
  Future<MediaUsage> usage() async => MediaUsage(
        usedBytes: b._media.values.where((m) => !m.expired).fold(0, (a, m) => a + m.bytes.length),
        capBytes: 8 * 1024 * 1024 * 1024,
        evictToBytes: 7680 * 1024 * 1024,
        files: b._media.values.where((m) => !m.expired).length,
        expiredFiles: b._media.values.where((m) => m.expired).length,
      );
}

/// A device's socket to the fake hub. [start] connects; [drop] simulates a lost connection
/// (call [connect] to come back, as the real connection's backoff would).
class FakeHubLink implements HubLink {
  FakeHubLink(this.b, this.deviceId, this.userId);
  final FakeChatBackend b;
  final String deviceId, userId;

  final _events = StreamController<Map<String, Object?>>.broadcast();
  final _connection = StreamController<bool>.broadcast();
  bool _connected = false;

  /// The hub stores the next message but the connection drops before the ack.
  bool dropNextAck = false;

  /// The hub stores messages from this device but doesn't fan them out (to create gaps elsewhere).
  bool holdFanOut = false;

  /// Event types this device never receives (to leave its local state stale on purpose).
  final dropEventTypes = <String>{};

  /// Frames this device sent, in order.
  final sent = <Map<String, Object?>>[];

  @override
  Stream<Map<String, Object?>> get events => _events.stream;

  @override
  Stream<bool> get connection => _connection.stream;

  @override
  bool get connected => _connected;

  @override
  bool send(Map<String, Object?> msg) {
    if (!_connected) return false;
    sent.add(msg);
    Future(() {
      if (_connected) b._hubFrame(this, msg);
    });
    return true;
  }

  void _deliver(Map<String, Object?> event) {
    Future(() {
      if (_connected && !_events.isClosed && !dropEventTypes.contains(event['type'])) _events.add(event);
    });
  }

  Future<void> connect() async {
    if (_connected) return;
    _connected = true;
    _connection.add(true);
    b._connected(this);
    await pump();
  }

  void drop() {
    if (!_connected) return;
    _connected = false;
    _connection.add(false);
    b._disconnected(this);
  }

  @override
  Future<void> start() => connect();

  @override
  Future<void> stop() async => drop();
}

/// Lets queued fake network traffic (timers of zero) and its handlers run.
Future<void> pump([int rounds = 20]) async {
  for (var i = 0; i < rounds; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}
