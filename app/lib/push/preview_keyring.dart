// ignore_for_file: prefer_initializing_formals
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
import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:drift/drift.dart' show TableUpdateQuery;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../chat/db/chat_db.dart';
import '../chat/providers.dart';
import '../crypto/encoding.dart';
import '../session/session_controller.dart';
import 'preview_setting.dart';

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

/// Keeps the store in step with the database while previews are on: writes now, rewrites
/// (debounced) when keys, devices, chats or users change, wipes on off. Writes are serialised, and
/// a generation counter drops any rebuild that finishes after off or dispose, so a late rewrite
/// can never bring the keyring back. Store errors are swallowed (a simulator has no entitlement).
class PreviewKeyringSync {
  PreviewKeyringSync({
    required ChatDb db,
    required PreviewKeyringStore store,
    Duration debounce = const Duration(milliseconds: 300),
  })  : _db = db,
        _store = store,
        _debounce = debounce;

  final ChatDb _db;
  final PreviewKeyringStore _store;
  final Duration _debounce;

  int _gen = 0;
  bool? _on; // null until the first setOn, so the first "off" always wipes
  StreamSubscription<Set<Object>>? _sub;
  Timer? _timer;
  Future<void> _chain = Future.value();

  Future<void> setOn(bool on) {
    if (on == _on) return _chain;
    _on = on;
    final gen = ++_gen;
    _stopListening();
    if (!on) return _enqueue(() => _store.wipe());
    _sub = _db
        .tableUpdates(TableUpdateQuery.onAllTables([_db.localKeys, _db.localDevices, _db.localChats, _db.localUsers]))
        .listen((_) {
      _timer?.cancel();
      _timer = Timer(_debounce, () => _enqueue(() => _rewrite(gen)));
    });
    return _enqueue(() => _rewrite(gen));
  }

  Future<void> dispose() async {
    _on = false;
    _gen++;
    _stopListening();
    await _chain;
  }

  void _stopListening() {
    _timer?.cancel();
    _timer = null;
    _sub?.cancel();
    _sub = null;
  }

  Future<void> _rewrite(int gen) async {
    if (gen != _gen) return;
    final json = await buildPreviewKeyring(_db);
    if (gen != _gen) return;
    await _store.write(json);
  }

  Future<void> _enqueue(Future<void> Function() job) {
    final next = _chain.then((_) async {
      try {
        await job();
      } catch (_) {
        // Best effort; never log keyring contents.
      }
    });
    return _chain = next;
  }
}

final previewKeyringStoreProvider = Provider<PreviewKeyringStore?>(
    (ref) => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS ? SecurePreviewKeyringStore() : null);

/// iOS only: mirrors the previews setting and the local database into the shared keychain item.
/// One sync lives per chat database while signed in; the setting drives it through a listener so
/// turning previews off reaches the same instance and wipes. A loading or reloading setting counts
/// as off (sign-out invalidates it), and signing out drops the sync altogether.
final previewKeyringSyncProvider = Provider<void>((ref) {
  final store = ref.watch(previewKeyringStoreProvider);
  if (store == null) return;
  if (!ref.watch(sessionProvider.select((s) => s is SignedIn))) return;
  final sync = PreviewKeyringSync(db: ref.watch(chatDbProvider), store: store);
  ref.onDispose(sync.dispose);
  ref.listen(previewsOnProvider, (_, n) => unawaited(sync.setOn(!n.isLoading && (n.value ?? false))),
      fireImmediately: true);
});
