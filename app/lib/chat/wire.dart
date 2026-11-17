// The chat API's JSON shapes (docs/protocol.md) and the interface the sync engine talks to.
import '../crypto/wrap.dart';

T _f<T>(Map<String, Object?> j, String k) {
  final v = j[k];
  if (v is T) return v;
  throw FormatException('bad $k');
}

List<Map<String, Object?>> _list(Map<String, Object?> j, String k) {
  final v = j[k];
  if (v is! List) throw FormatException('bad $k');
  return [
    for (final x in v)
      if (x is Map<String, Object?>) x else throw FormatException('bad $k item'),
  ];
}

class DeviceDto {
  const DeviceDto({
    required this.id,
    required this.userId,
    required this.name,
    required this.platform,
    required this.encPub,
    required this.signPub,
    required this.certSig,
    required this.revoked,
  });

  final String id, userId, name, platform, encPub, signPub, certSig;
  final bool revoked;

  factory DeviceDto.fromJson(String userId, Map<String, Object?> j) => DeviceDto(
        id: _f(j, 'id'),
        userId: userId,
        name: _f(j, 'name'),
        platform: _f(j, 'platform'),
        encPub: _f(j, 'encPub'),
        signPub: _f(j, 'signPub'),
        certSig: _f(j, 'certSig'),
        revoked: _f(j, 'revoked'),
      );
}

class UserDto {
  const UserDto({
    required this.id,
    required this.name,
    required this.isAdmin,
    required this.identityPub,
    required this.devices,
    this.resets = const [],
    this.adminProof,
    this.deleted = false,
  });

  final String id, name, identityPub;
  final bool isAdmin;

  /// The account was deleted (docs/protocol.md "Deleting an account"): listed so old certificates
  /// still verify, but gone from the family.
  final bool deleted;
  final List<DeviceDto> devices;

  /// Who made this user an admin, signed; null for the bootstrapped first admin (and non-admins).
  final AdminProofDto? adminProof;

  /// The user's signed account resets, oldest first: their identity key history.
  final List<ResetDto> resets;

  factory UserDto.fromJson(Map<String, Object?> j) {
    final id = _f<String>(j, 'id');
    return UserDto(
      id: id,
      name: _f(j, 'name'),
      isAdmin: _f(j, 'isAdmin'),
      identityPub: _f(j, 'identityPub'),
      devices: [for (final d in _list(j, 'devices')) DeviceDto.fromJson(id, d)],
      resets: j['resets'] == null ? const [] : [for (final r in _list(j, 'resets')) ResetDto.fromJson(r)],
      adminProof: switch (j['adminProof']) {
        final Map<String, Object?> p => AdminProofDto(byUserId: _f(p, 'byUserId'), signerPub: _f(p, 'signerPub'), sig: _f(p, 'sig')),
        null => null,
        _ => throw const FormatException('bad adminProof'),
      },
      deleted: j['deleted'] == true,
    );
  }
}

/// `"famchat-admin-v1" ‖ str(userId) ‖ str(byUserId)` signed by [signerPub], the promoter's identity key then.
class AdminProofDto {
  const AdminProofDto({required this.byUserId, required this.signerPub, required this.sig});
  final String byUserId, signerPub, sig;
}

/// A signed account reset as the directory lists it (docs/protocol.md "Account resets"). Unverified:
/// lib/chat/resets.dart decides what it proves.
class ResetDto {
  const ResetDto({
    required this.id,
    required this.signerUserId,
    required this.signerKind,
    required this.signerPub,
    required this.recoverySig,
    required this.oldIdentityPub,
    required this.claimPub,
    required this.createdAt,
    required this.sig,
    required this.newIdentityPub,
    required this.claimSig,
    required this.completedAt,
  });

  final String id, signerUserId, signerKind, signerPub, oldIdentityPub, claimPub, sig;
  final String? recoverySig, newIdentityPub, claimSig;
  final int createdAt;
  final int? completedAt;

  factory ResetDto.fromJson(Map<String, Object?> j) => ResetDto(
        id: _f(j, 'id'),
        signerUserId: _f(j, 'signerUserId'),
        signerKind: _f(j, 'signerKind'),
        signerPub: _f(j, 'signerPub'),
        recoverySig: _f<String?>(j, 'recoverySig'),
        oldIdentityPub: _f(j, 'oldIdentityPub'),
        claimPub: _f(j, 'claimPub'),
        createdAt: _f(j, 'createdAt'),
        sig: _f(j, 'sig'),
        newIdentityPub: _f<String?>(j, 'newIdentityPub'),
        claimSig: _f<String?>(j, 'claimSig'),
        completedAt: _f<int?>(j, 'completedAt'),
      );
}

class MemberDto {
  const MemberDto({required this.userId, required this.joinedSeq, required this.lastReadSeq});
  final String userId;
  final int joinedSeq, lastReadSeq;

  factory MemberDto.fromJson(Map<String, Object?> j) =>
      MemberDto(userId: _f(j, 'userId'), joinedSeq: _f(j, 'joinedSeq'), lastReadSeq: _f(j, 'lastReadSeq'));
}

class ChatDto {
  const ChatDto({
    required this.id,
    required this.kind,
    required this.title,
    required this.createdBy,
    required this.currentEpoch,
    required this.epochReady,
    required this.lastSeq,
    required this.lastMessageAt,
    required this.createdAt,
    required this.members,
    this.mutedUntil,
  });

  final String id, kind, createdBy;

  /// This user's mute: no notifications from the chat until then (Unix ms), or null.
  final int? mutedUntil;
  final String? title;
  final int currentEpoch, lastSeq, createdAt;
  final int? lastMessageAt;
  final bool epochReady;
  final List<MemberDto> members;

  bool get isDirect => kind == 'direct';

  factory ChatDto.fromJson(Map<String, Object?> j) => ChatDto(
        id: _f(j, 'id'),
        kind: _f(j, 'kind'),
        title: _f<String?>(j, 'title'),
        createdBy: _f(j, 'createdBy'),
        currentEpoch: _f(j, 'currentEpoch'),
        epochReady: _f(j, 'epochReady'),
        lastSeq: _f(j, 'lastSeq'),
        lastMessageAt: _f<int?>(j, 'lastMessageAt'),
        createdAt: _f(j, 'createdAt'),
        members: [for (final m in _list(j, 'members')) MemberDto.fromJson(m)],
        mutedUntil: _f<int?>(j, 'mutedUntil'),
      );
}

class MessageDto {
  const MessageDto({
    required this.chatId,
    required this.seq,
    required this.id,
    required this.senderUserId,
    required this.senderDeviceId,
    required this.envelope,
    required this.createdAt,
  });

  final String chatId, id, senderUserId, senderDeviceId;
  final int seq, createdAt;
  final Map<String, Object?> envelope;

  factory MessageDto.fromJson(Map<String, Object?> j) => MessageDto(
        chatId: _f(j, 'chatId'),
        seq: _f(j, 'seq'),
        id: _f(j, 'id'),
        senderUserId: _f(j, 'senderUserId'),
        senderDeviceId: _f(j, 'senderDeviceId'),
        envelope: _f(j, 'envelope'),
        createdAt: _f(j, 'createdAt'),
      );
}

class MissingWrap {
  const MissingWrap({required this.chatId, required this.epoch, required this.deviceId});
  final String chatId, deviceId;
  final int epoch;

  factory MissingWrap.fromJson(Map<String, Object?> j) =>
      MissingWrap(chatId: _f(j, 'chatId'), epoch: _f(j, 'epoch'), deviceId: _f(j, 'deviceId'));
}

/// The REST side of the chat protocol. Errors are `ApiException` / `NetworkException` /
/// `SignedOutException` from `lib/api/models.dart`; malformed bodies throw [FormatException].
abstract interface class ChatApi {
  Future<List<UserDto>> users();
  Future<List<ChatDto>> chats();
  Future<ChatDto> chat(String id);
  Future<({ChatDto chat, bool created})> createChat({
    required String id,
    required String kind,
    String? title,
    required List<String> userIds,
    required List<ChatKeyWrap> wraps,
  });
  Future<ChatDto> addMembers(String chatId, List<String> userIds, List<ChatKeyWrap> wraps);
  Future<void> removeMember(String chatId, String userId);

  /// Mutes the chat for this user until [until] (Unix ms), or unmutes it (null).
  Future<void> muteChat(String chatId, int? until);
  Future<void> createEpoch(String chatId, int epoch, List<ChatKeyWrap> wraps);
  Future<List<MessageDto>> messages(String chatId, {int? after, int? before, int limit = 100});
  Future<List<ChatKeyWrap>> wraps({String? chatId});
  Future<int> putWraps(List<ChatKeyWrap> wraps);
  Future<List<MissingWrap>> missingWraps();
  Future<String> wsTicket();
}
