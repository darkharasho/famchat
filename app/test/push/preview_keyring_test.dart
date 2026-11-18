import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:famchat/chat/db/chat_db.dart';
import 'package:famchat/crypto/encoding.dart';
import 'package:famchat/push/preview_keyring.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:famchat/chat/providers.dart';
import 'package:famchat/push/preview_setting.dart';
import 'package:famchat/session/session_controller.dart';
import 'package:famchat/session/stored_session.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

Uint8List key(int seed) => Uint8List.fromList(List.generate(32, (i) => (i + seed) % 256));

void main() {
  late ChatDb db;
  setUp(() => db = ChatDb(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<void> addDevice(String id,
          {String user = 'bob', bool trusted = true, bool certValid = true, bool revoked = false}) =>
      db.putDevice(DeviceRow(
        id: id,
        userId: user,
        name: 'Phone',
        encPub: 'x',
        signPub: b64url(key(id.length)),
        certSig: 'x',
        revoked: revoked,
        certValid: certValid,
        trusted: trusted,
      ));

  Future<void> addChat(String id, String kind) => db.into(db.localChats).insert(LocalChatsCompanion.insert(
        id: id,
        kind: kind,
        createdBy: 'bob',
        currentEpoch: 1,
        epochReady: true,
        lastSeq: 0,
        createdAt: 0,
        title: const Value(null),
      ));

  Future<Map<String, Object?>> built() async => jsonDecode(await buildPreviewKeyring(db)) as Map<String, Object?>;

  test('holds every epoch of every chat', () async {
    await db.putKey('C1', 1, key(1));
    await db.putKey('C1', 2, key(2));
    await db.putKey('G1', 1, key(3));
    expect((await built())['keys'], {
      'C1': {'1': b64url(key(1)), '2': b64url(key(2))},
      'G1': {'1': b64url(key(3))},
    });
  });

  test('only trusted devices with valid certs', () async {
    await addDevice('untrusted', trusted: false);
    await addDevice('badcert', certValid: false);
    await addDevice('good');
    final devices = (await built())['devices'] as Map;
    expect(devices.keys, ['good']);
    expect(devices['good'], {'userId': 'bob', 'signPub': b64url(key(4)), 'revoked': false});
  });

  test('revoked device kept with revoked true', () async {
    await addDevice('gone', revoked: true);
    expect(((await built())['devices'] as Map)['gone']['revoked'], true);
  });

  test('groups lists group chats only', () async {
    await addChat('G2', 'group');
    await addChat('D1', 'direct');
    await addChat('G1', 'group');
    expect((await built())['groups'], ['G1', 'G2']);
  });

  test('names maps user ids to names', () async {
    for (final (id, name) in [('bob', 'Bob'), ('amy', 'Amy')]) {
      await db.putUser(UserRow(
          id: id, name: name, isAdmin: false, identityPub: 'x', trustedIdentityPub: 'x', knownIdentityPubs: '[]', pinnedAdmin: false, familyIds: '[]'));
    }
    expect((await built())['names'], {'amy': 'Amy', 'bob': 'Bob'});
  });

  test('is byte-identical for the same data inserted in another order', () async {
    Future<String> fill(List<int> order) async {
      await db.delete(db.localKeys).go();
      for (final i in order) {
        await db.putKey('C$i', 2, key(i));
        await db.putKey('C$i', 1, key(i + 10));
      }
      return buildPreviewKeyring(db);
    }

    expect(await fill([1, 2, 3]), await fill([3, 1, 2]));
  });

  test('empty db gives the empty keyring', () async {
    expect(await buildPreviewKeyring(db), '{"v":1,"keys":{},"devices":{},"groups":[],"names":{}}');
  });

  test('SecurePreviewKeyringStore uses the shared access group', () async {
    FlutterSecureStorage.setMockInitialValues({});
    const o = SecurePreviewKeyringStore.iosOptions;
    expect(o.groupId, 'group.dev.famchat.app');
    expect(o.accountName, 'dev.famchat.preview');
    expect(o.accessibility, KeychainAccessibility.first_unlock_this_device);
    expect(o.synchronizable, false);

    const storage = FlutterSecureStorage();
    final store = SecurePreviewKeyringStore(storage);
    await store.write('{"v":1}');
    expect(await storage.read(key: previewKeyringKey, iOptions: o), '{"v":1}');
    await store.wipe();
    expect(await storage.read(key: previewKeyringKey, iOptions: o), isNull);
  });

  test('MemoryPreviewKeyringStore counts writes', () async {
    final m = MemoryPreviewKeyringStore();
    await m.write('a');
    expect((m.value, m.writes), ('a', 1));
    await m.wipe();
    expect(m.value, isNull);
  });

  group('PreviewKeyringSync', () {
    Future<void> pump([Duration d = Duration.zero]) => Future<void>.delayed(d);

    (MemoryPreviewKeyringStore, PreviewKeyringSync) make({Duration debounce = Duration.zero}) {
      final store = MemoryPreviewKeyringStore();
      final sync = PreviewKeyringSync(db: db, store: store, debounce: debounce);
      addTearDown(sync.dispose);
      return (store, sync);
    }

    test('setOn true writes the keyring now', () async {
      final (store, sync) = make();
      await sync.setOn(true);
      expect(store.value, '{"v":1,"keys":{},"devices":{},"groups":[],"names":{}}');
    });

    test('a new chat key rewrites', () async {
      final (store, sync) = make();
      await sync.setOn(true);
      await db.putKey('C1', 7, key(1));
      await pump(const Duration(milliseconds: 20));
      expect(store.value, contains('"7":"${b64url(key(1))}"'));
    });

    test('a device revoked rewrites', () async {
      final (store, sync) = make();
      await addDevice('d1');
      await sync.setOn(true);
      expect(store.value, contains('"revoked":false'));
      await addDevice('d1', revoked: true);
      await pump(const Duration(milliseconds: 20));
      expect(store.value, contains('"revoked":true'));
    });

    test('a renamed user rewrites', () async {
      final (store, sync) = make();
      UserRow user(String name) => UserRow(
          id: 'bob', name: name, isAdmin: false, identityPub: 'x', trustedIdentityPub: 'x', knownIdentityPubs: '[]', pinnedAdmin: false, familyIds: '[]');
      await db.putUser(user('Bob'));
      await sync.setOn(true);
      expect(store.value, contains('"bob":"Bob"'));
      await db.putUser(user('Robert'));
      await pump(const Duration(milliseconds: 20));
      expect(store.value, contains('"bob":"Robert"'));
    });

    test('turning previews off wipes', () async {
      final (store, sync) = make();
      await sync.setOn(true);
      await sync.setOn(false);
      expect(store.value, isNull);
      final writes = store.writes;
      await db.putKey('C1', 1, key(1));
      await pump(const Duration(milliseconds: 20));
      expect(store.value, isNull);
      expect(store.writes, writes);
    });

    test('stop cancels a pending rewrite', () async {
      final (store, sync) = make(debounce: const Duration(milliseconds: 50));
      await sync.setOn(true);
      await db.putKey('C1', 1, key(1));
      await pump();
      await sync.setOn(false);
      await pump(const Duration(milliseconds: 100));
      expect(store.value, isNull);
    });

    test('a rebuild held open across off is dropped (generation check after the build)', () async {
      final gdb = _GatedDb();
      addTearDown(gdb.close);
      final store = MemoryPreviewKeyringStore();
      final sync = PreviewKeyringSync(db: gdb, store: store, debounce: Duration.zero);
      addTearDown(sync.dispose);
      gdb.gate = Completer<void>();
      final on = sync.setOn(true);
      await pump(const Duration(milliseconds: 10));
      expect(gdb.reads, 1);
      final off = sync.setOn(false);
      gdb.gate!.complete();
      await Future.wait([on, off]);
      expect(store.writes, 0);
      expect(store.value, isNull);
    });

    test('a wipe waits for a write already in flight (serialised)', () async {
      final store = _GatedStore();
      final sync = PreviewKeyringSync(db: db, store: store, debounce: Duration.zero);
      addTearDown(sync.dispose);
      final on = sync.setOn(true);
      await pump(const Duration(milliseconds: 10));
      expect(store.writeStarted, isTrue);
      final off = sync.setOn(false);
      await pump(const Duration(milliseconds: 10));
      expect(store.wiped, isFalse);
      store.gate.complete();
      await Future.wait([on, off]);
      expect(store.value, isNull);
    });

    test('the first off wipes even when nothing was on', () async {
      final (store, sync) = make();
      store.value = 'left behind';
      await sync.setOn(false);
      expect(store.value, isNull);
    });

    test('a throwing store does not throw out of setOn', () async {
      final sync = PreviewKeyringSync(db: db, store: _ThrowingStore(), debounce: Duration.zero);
      addTearDown(sync.dispose);
      await sync.setOn(true);
      await sync.setOn(false);
    });
  });

  group('previewKeyringSyncProvider', () {
    test('turning previews on then off from the setting wipes the keyring', () async {
      SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
      final store = MemoryPreviewKeyringStore();
      final c = ProviderContainer(overrides: [
        previewKeyringStoreProvider.overrideWithValue(store),
        chatDbProvider.overrideWithValue(db),
        sessionProvider.overrideWith(_SignedInStub.new),
      ]);
      addTearDown(c.dispose);
      c.listen(previewKeyringSyncProvider, (_, _) {});
      await db.putKey('C1', 1, key(1));
      await c.read(previewsOnProvider.future);
      await c.read(previewsOnProvider.notifier).set(true);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(store.value, contains('"C1"'));
      await c.read(previewsOnProvider.notifier).set(false);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(store.value, isNull);
    });

    ProviderContainer containerWith(MemoryPreviewKeyringStore store) {
      SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
      final c = ProviderContainer(overrides: [
        previewKeyringStoreProvider.overrideWithValue(store),
        chatDbProvider.overrideWithValue(db),
        sessionProvider.overrideWith(_SignedInStub.new),
        previewsOnProvider.overrideWith(_ControlledPreviews.new),
      ]);
      addTearDown(c.dispose);
      return c;
    }

    test('a reloading setting that still holds true counts as off', () async {
      final store = MemoryPreviewKeyringStore();
      final c = containerWith(store);
      c.listen(previewKeyringSyncProvider, (_, _) {});
      await db.putKey('C1', 1, key(1));
      await c.read(previewsOnProvider.future);
      await c.read(previewsOnProvider.notifier).set(true);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(store.value, contains('"C1"'));
      (c.read(previewsOnProvider.notifier) as _ControlledPreviews).reloading();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(store.value, isNull);
    });

    test('once signed out the sync is gone and nothing rewrites the keyring', () async {
      final store = MemoryPreviewKeyringStore();
      final c = containerWith(store);
      c.listen(previewKeyringSyncProvider, (_, _) {});
      await c.read(previewsOnProvider.future);
      await c.read(previewsOnProvider.notifier).set(true);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(store.value, isNotNull);
      (c.read(sessionProvider.notifier) as _SignedInStub).endNow();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await store.wipe();
      await db.putKey('C1', 1, key(1));
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(store.value, isNull);
    });
  });
}

class _ControlledPreviews extends PreviewsOnNotifier {
  bool _hang = false;

  @override
  Future<bool> build() => _hang ? Completer<bool>().future : super.build();

  /// Reloads and never finishes: loading, with the previous true still readable.
  void reloading() {
    _hang = true;
    ref.invalidateSelf();
  }
}

class _SignedInStub extends SessionController {
  void endNow() => state = const SignedOut();

  @override
  SessionState build() => SignedIn(StoredSession(
      userId: 'u',
      deviceId: 'd',
      deviceName: 'Pixel',
      refreshToken: 'r',
      isAdmin: false,
      name: null,
      identitySeed: 'x',
      encSeed: 'x',
      signSeed: 'x'));
}

class _ThrowingStore implements PreviewKeyringStore {
  @override
  Future<void> write(String json) async => throw StateError('no entitlement');
  @override
  Future<void> wipe() async => throw StateError('no entitlement');
}

class _GatedDb extends ChatDb {
  _GatedDb() : super(NativeDatabase.memory());
  Completer<void>? gate;
  int reads = 0;

  @override
  Future<List<KeyRow>> allKeys() async {
    reads++;
    await gate?.future;
    return super.allKeys();
  }
}

class _GatedStore extends MemoryPreviewKeyringStore {
  final gate = Completer<void>();
  bool writeStarted = false, wiped = false;

  @override
  Future<void> write(String json) async {
    writeStarted = true;
    await gate.future;
    await super.write(json);
  }

  @override
  Future<void> wipe() async {
    wiped = true;
    await super.wipe();
  }
}
