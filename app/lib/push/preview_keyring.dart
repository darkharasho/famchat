// The preview keyring: what the iPhone Notification Service Extension needs to decrypt a push and
// show its text. Built from the local database and written whole to one shared keychain item
// (generic password, service `dev.famchat.preview`, account `preview_keyring`, access group
// `group.dev.famchat.app`, after-first-unlock, this device only). It exists only while previews are
// on and the user is signed in; it is wiped when they turn off or the session ends.
//
// Schema v1 (UTF-8 JSON; every map and list is sorted, so the same data gives the same bytes;
// binary values are unpadded base64url):
//   {"v":1,
//    "keys":{"<chatId>":{"<epoch>":"<32-byte chat key>"}},
//    "devices":{"<deviceId>":{"userId":"…","signPub":"…","revoked":false}},
//    "groups":["<chatId of each group chat>"],
//    "names":{"<userId>":"<name>"}}
// Only devices that are trusted and have a valid cert are listed; revoked ones stay, flagged.
import 'dart:collection';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../chat/db/chat_db.dart';
import '../crypto/encoding.dart';

const previewKeyringGroup = 'group.dev.famchat.app',
    previewKeyringService = 'dev.famchat.preview',
    previewKeyringKey = 'preview_keyring';

Future<String> buildPreviewKeyring(ChatDb db) async {
  final keys = SplayTreeMap<String, SplayTreeMap<String, String>>();
  for (final k in await db.allKeys()) {
    (keys[k.chatId] ??= SplayTreeMap())['${k.epoch}'] = b64url(k.key);
  }
  final devices = SplayTreeMap<String, Map<String, Object>>();
  for (final d in await db.allDevices()) {
    if (!d.certValid || !d.trusted) continue;
    devices[d.id] = {'userId': d.userId, 'signPub': d.signPub, 'revoked': d.revoked};
  }
  final groups = [
    for (final c in await db.allChats())
      if (c.kind == 'group') c.id
  ]..sort();
  final names = SplayTreeMap<String, String>();
  for (final u in await db.allUsers()) {
    names[u.id] = u.name;
  }
  return jsonEncode({'v': 1, 'keys': keys, 'devices': devices, 'groups': groups, 'names': names});
}

abstract interface class PreviewKeyringStore {
  Future<void> write(String json);
  Future<void> wipe();
}

class SecurePreviewKeyringStore implements PreviewKeyringStore {
  SecurePreviewKeyringStore([FlutterSecureStorage? storage]) : _s = storage ?? const FlutterSecureStorage();

  static const iosOptions = IOSOptions(
    groupId: previewKeyringGroup,
    accountName: previewKeyringService,
    accessibility: KeychainAccessibility.first_unlock_this_device,
    synchronizable: false,
  );

  final FlutterSecureStorage _s;

  @override
  Future<void> write(String json) => _s.write(key: previewKeyringKey, value: json, iOptions: iosOptions);

  @override
  Future<void> wipe() => _s.delete(key: previewKeyringKey, iOptions: iosOptions);
}

class MemoryPreviewKeyringStore implements PreviewKeyringStore {
  String? value;
  int writes = 0;

  @override
  Future<void> write(String json) async {
    value = json;
    writes++;
  }

  @override
  Future<void> wipe() async => value = null;
}
