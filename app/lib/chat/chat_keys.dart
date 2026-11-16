// Chat keys per epoch: wrapping for member devices, verifying and opening wraps addressed to this
// device, creating a new epoch after a leave or removal, and adding wraps other devices lack.
import 'dart:async';
import 'dart:typed_data';

import '../api/models.dart';
import '../crypto/encoding.dart';
import '../crypto/keys.dart';
import '../crypto/wrap.dart';
import 'db/chat_db.dart';
import 'directory.dart';
import 'wire.dart';

class ChatKeys {
  ChatKeys({required this.db, required this.api, required this.directory, required this.me});

  final ChatDb db;
  final ChatApi api;
  final Directory directory;
  final LocalIdentity me;
  ChatDb get _db => db;
  ChatApi get _api => api;
  Directory get _dir => directory;
  LocalIdentity get _me => me;
  final _ensuring = <String, Future<bool>>{};

  Future<Uint8List?> key(String chatId, int epoch) => _db.key(chatId, epoch);

  /// One signed wrap of [key] per device in [devices].
  Future<List<ChatKeyWrap>> wrapKey({
    required String chatId,
    required int epoch,
    required List<int> key,
    required List<VerifiedDevice> devices,
  }) async => [
        for (final d in devices)
          await wrapChatKey(
            chatKey: key,
            chatId: chatId,
            epoch: epoch,
            recipientDeviceId: d.id,
            recipientEncPub: d.encPub,
            wrapperDeviceId: _me.deviceId,
            wrapperSignKey: _me.keys.sign,
          ),
      ];

  /// Fetches wraps for this device, keeps the ones that verify and returns how many keys were new.
  /// A wrap counts only if its wrapper is a live device whose certificate chains to a current
  /// member's identity key (a revoked device's key may be in the wrong hands).
  Future<int> fetch({String? chatId}) async {
    final wraps = await _api.wraps(chatId: chatId);
    var added = 0;
    for (final w in wraps) {
      if (await _db.key(w.chatId, w.epoch) != null) continue;
      final members = {for (final m in await _db.membersOf(w.chatId)) m.userId};
      final wrapper = await _dir.device(w.wrapperDeviceId);
      if (wrapper == null || wrapper.revoked || !wrapper.trusted || !members.contains(wrapper.userId)) continue;
      try {
        final k = await unwrapChatKey(
          wrap: w,
          chatId: w.chatId,
          epoch: w.epoch,
          myDeviceId: _me.deviceId,
          me: _me.keys,
          wrapperSignPub: wrapper.signPub,
        );
        await _db.putKey(w.chatId, w.epoch, k);
        added++;
      } on CryptoFailure {
        // Forged, moved or corrupt: never yields a key.
      }
    }
    return added;
  }

  /// Makes sure this device holds the key of the chat's current epoch, creating the epoch if no
  /// one has yet. False if that isn't possible right now (no wrap for us yet, or not a member).
  Future<bool> ensureCurrentEpoch(String chatId) =>
      _ensuring[chatId] ??= _ensure(chatId).whenComplete(() {
        _ensuring.remove(chatId); // a block body: returning the removed future would await itself
      });

  Future<bool> _ensure(String chatId) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      final chat = await _db.chatById(chatId);
      if (chat == null) return false;
      if (await _db.key(chatId, chat.currentEpoch) != null) return true;
      if (chat.epochReady) {
        await fetch(chatId: chatId);
        return await _db.key(chatId, chat.currentEpoch) != null;
      }
      final key = newChatKey();
      final members = [for (final m in await _db.membersOf(chatId)) m.userId];
      final wraps = await wrapKey(chatId: chatId, epoch: chat.currentEpoch, key: key, devices: await _dir.liveDevices(members));
      try {
        await _api.createEpoch(chatId, chat.currentEpoch, wraps);
        await _db.putKey(chatId, chat.currentEpoch, key);
        await _refreshChat(chatId);
        return true;
      } on ApiException catch (e) {
        switch (e.code) {
          case 'epoch_exists' || 'stale_epoch':
            await _refreshChat(chatId);
          case 'wraps_mismatch':
            await _dir.refresh();
            await _refreshChat(chatId);
          default:
            rethrow;
        }
      }
    }
    return false;
  }

  Future<void> _refreshChat(String chatId) async {
    try {
      await _db.upsertChat(await _api.chat(chatId));
    } on ApiException catch (e) {
      if (e.code == 'not_found') {
        await _db.deleteChat(chatId);
      } else {
        rethrow;
      }
    }
  }

  /// Wraps of every epoch key this device holds for [chatId], for the live devices of [userIds]
  /// (new members, so they can read the history).
  Future<List<ChatKeyWrap>> wrapsForNewDevices(String chatId, List<String> userIds) async {
    final devices = await _dir.liveDevices(userIds);
    return [
      for (final k in await _db.keysOf(chatId))
        ...await wrapKey(chatId: chatId, epoch: k.epoch, key: k.key, devices: devices),
    ];
  }

  /// Missing-wrap repair: wraps keys this device holds for member devices that lack them.
  /// Returns how many the server accepted.
  Future<int> repairMissing() async {
    final missing = await _api.missingWraps();
    final wraps = <ChatKeyWrap>[];
    for (final m in missing) {
      final key = await _db.key(m.chatId, m.epoch);
      if (key == null) continue;
      final d = await _dir.device(m.deviceId);
      if (d == null || d.revoked || !d.trusted) continue;
      final members = {for (final x in await _db.membersOf(m.chatId)) x.userId};
      if (!members.contains(d.userId)) continue;
      wraps.addAll(await wrapKey(chatId: m.chatId, epoch: m.epoch, key: key, devices: [d]));
    }
    var added = 0;
    for (var i = 0; i < wraps.length; i += 500) {
      added += await _api.putWraps(wraps.sublist(i, i + 500 > wraps.length ? wraps.length : i + 500));
    }
    return added;
  }
}
