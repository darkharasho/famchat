import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:famchat/chat/db/chat_db.dart';
import 'package:famchat/crypto/encoding.dart';
import 'package:famchat/push/preview_keyring.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

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
}
