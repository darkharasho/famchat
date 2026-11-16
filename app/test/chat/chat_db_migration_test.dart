import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:famchat/chat/db/chat_db.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('schema 1 to 2: reset banners table, and the admins this device knew are pinned', () async {
    final dir = await Directory.systemTemp.createTemp('famchat_migration');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/chat.db');

    // Make a current database, then (before the next open migrates it) turn it back into schema 1:
    // no local_resets, no pinned_admin (and no schema 3 deleted).
    final fresh = ChatDb(NativeDatabase(file));
    await fresh.customSelect('SELECT 1').get();
    await fresh.close();

    final db = ChatDb(NativeDatabase(file, setup: (raw) {
      raw
        ..execute('DROP TABLE local_resets')
        ..execute('ALTER TABLE local_users DROP COLUMN pinned_admin')
        ..execute('ALTER TABLE local_users DROP COLUMN deleted')
        ..execute("INSERT INTO local_users (id, name, is_admin, identity_pub, trusted_identity_pub) VALUES ('A', 'Ann', 1, 'k', 'k')")
        ..execute("INSERT INTO local_users (id, name, is_admin, identity_pub, trusted_identity_pub) VALUES ('B', 'Bo', 0, 'k2', 'k2')")
        ..execute('PRAGMA user_version = 1');
    }));
    addTearDown(db.close);
    expect((await db.userById('A'))!.pinnedAdmin, isTrue);
    expect((await db.userById('B'))!.pinnedAdmin, isFalse);
    expect(await db.metaValue(ChatDb.adminsPinnedKey), '1');
    await db.recordReset(id: 'R', userId: 'B', signerUserId: 'A', signerKind: 'admin', createdAt: 1);
    expect((await db.allResets()).single.id, 'R');
  });

  test('schema 2 to 3: users get a deleted flag, unset for the users already known', () async {
    final dir = await Directory.systemTemp.createTemp('famchat_migration');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/chat.db');
    final fresh = ChatDb(NativeDatabase(file));
    await fresh.customSelect('SELECT 1').get();
    await fresh.close();

    final db = ChatDb(NativeDatabase(file, setup: (raw) {
      raw
        ..execute('ALTER TABLE local_users DROP COLUMN deleted')
        ..execute("INSERT INTO local_users (id, name, is_admin, identity_pub, trusted_identity_pub) VALUES ('A', 'Ann', 1, 'k', 'k')")
        ..execute('PRAGMA user_version = 2');
    }));
    addTearDown(db.close);
    expect((await db.userById('A'))!.deleted, isNull);
    await db.putUser((await db.userById('A'))!.copyWith(deleted: const Value(true)));
    expect((await db.userById('A'))!.deleted, isTrue);
  });
}
