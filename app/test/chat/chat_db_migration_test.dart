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
        ..execute('ALTER TABLE local_chats DROP COLUMN muted_until')
        ..execute('ALTER TABLE local_chats DROP COLUMN draft')
        ..execute('ALTER TABLE local_users DROP COLUMN avatar_key')
        ..execute('ALTER TABLE local_users DROP COLUMN former')
        ..execute('ALTER TABLE local_chats DROP COLUMN family_id')
        ..execute('ALTER TABLE local_users DROP COLUMN family_ids')
        ..execute('ALTER TABLE local_chats DROP COLUMN pinned_at')
        ..execute('ALTER TABLE local_chats DROP COLUMN archived_at')
        ..execute('ALTER TABLE local_chats DROP COLUMN marked_unread')
        ..execute('ALTER TABLE local_chats DROP COLUMN avatar_key')
        ..execute('ALTER TABLE local_users DROP COLUMN last_seen_at')
        ..execute("INSERT INTO local_users (id, name, is_admin, identity_pub, trusted_identity_pub) VALUES ('A', 'Ann', 1, 'k', 'k')")
        ..execute("INSERT INTO local_users (id, name, is_admin, identity_pub, trusted_identity_pub) VALUES ('B', 'Bo', 0, 'k2', 'k2')")
        ..execute('DROP TABLE local_stars')
        ..execute('DROP TABLE local_scheduled')
        ..execute('DROP TABLE local_reminders')
        ..execute('ALTER TABLE local_messages DROP COLUMN scheduled_for')
        ..execute('DROP INDEX local_messages_expires_at')
        ..execute('ALTER TABLE local_messages DROP COLUMN disappear_secs')
        ..execute('ALTER TABLE local_messages DROP COLUMN expires_at')
        ..execute('ALTER TABLE local_chats DROP COLUMN disappear_secs')
        ..execute('ALTER TABLE local_chats DROP COLUMN disappear_changed_by')
        ..execute('ALTER TABLE local_chats DROP COLUMN disappear_changed_at')
        ..execute('ALTER TABLE local_chats DROP COLUMN disappear_changed_seq')
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
        ..execute('ALTER TABLE local_chats DROP COLUMN muted_until')
        ..execute('ALTER TABLE local_chats DROP COLUMN draft')
        ..execute('ALTER TABLE local_users DROP COLUMN avatar_key')
        ..execute('ALTER TABLE local_users DROP COLUMN former')
        ..execute('ALTER TABLE local_chats DROP COLUMN family_id')
        ..execute('ALTER TABLE local_users DROP COLUMN family_ids')
        ..execute('ALTER TABLE local_chats DROP COLUMN pinned_at')
        ..execute('ALTER TABLE local_chats DROP COLUMN archived_at')
        ..execute('ALTER TABLE local_chats DROP COLUMN marked_unread')
        ..execute('ALTER TABLE local_chats DROP COLUMN avatar_key')
        ..execute('ALTER TABLE local_users DROP COLUMN last_seen_at')
        ..execute("INSERT INTO local_users (id, name, is_admin, identity_pub, trusted_identity_pub) VALUES ('A', 'Ann', 1, 'k', 'k')")
        ..execute('DROP TABLE local_stars')
        ..execute('DROP TABLE local_scheduled')
        ..execute('DROP TABLE local_reminders')
        ..execute('ALTER TABLE local_messages DROP COLUMN scheduled_for')
        ..execute('DROP INDEX local_messages_expires_at')
        ..execute('ALTER TABLE local_messages DROP COLUMN disappear_secs')
        ..execute('ALTER TABLE local_messages DROP COLUMN expires_at')
        ..execute('ALTER TABLE local_chats DROP COLUMN disappear_secs')
        ..execute('ALTER TABLE local_chats DROP COLUMN disappear_changed_by')
        ..execute('ALTER TABLE local_chats DROP COLUMN disappear_changed_at')
        ..execute('ALTER TABLE local_chats DROP COLUMN disappear_changed_seq')
        ..execute('PRAGMA user_version = 2');
    }));
    addTearDown(db.close);
    expect((await db.userById('A'))!.deleted, isNull);
    await db.putUser((await db.userById('A'))!.copyWith(deleted: const Value(true)));
    expect((await db.userById('A'))!.deleted, isTrue);
  });

  test('schema 3 to 4: chats get a mute time, unset for the chats already stored', () async {
    final dir = await Directory.systemTemp.createTemp('famchat_migration');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/chat.db');
    final fresh = ChatDb(NativeDatabase(file));
    await fresh.customSelect('SELECT 1').get();
    await fresh.close();

    final db = ChatDb(NativeDatabase(file, setup: (raw) {
      raw
        ..execute('ALTER TABLE local_chats DROP COLUMN muted_until')
        ..execute('ALTER TABLE local_chats DROP COLUMN draft')
        ..execute('ALTER TABLE local_users DROP COLUMN avatar_key')
        ..execute('ALTER TABLE local_users DROP COLUMN former')
        ..execute('ALTER TABLE local_chats DROP COLUMN family_id')
        ..execute('ALTER TABLE local_users DROP COLUMN family_ids')
        ..execute('ALTER TABLE local_chats DROP COLUMN pinned_at')
        ..execute('ALTER TABLE local_chats DROP COLUMN archived_at')
        ..execute('ALTER TABLE local_chats DROP COLUMN marked_unread')
        ..execute('ALTER TABLE local_chats DROP COLUMN avatar_key')
        ..execute('ALTER TABLE local_users DROP COLUMN last_seen_at')
        ..execute("INSERT INTO local_chats (id, kind, created_by, current_epoch, epoch_ready, last_seq, created_at) "
            "VALUES ('C', 'direct', 'A', 1, 1, 0, 0)")
        ..execute('DROP TABLE local_stars')
        ..execute('DROP TABLE local_scheduled')
        ..execute('DROP TABLE local_reminders')
        ..execute('ALTER TABLE local_messages DROP COLUMN scheduled_for')
        ..execute('DROP INDEX local_messages_expires_at')
        ..execute('ALTER TABLE local_messages DROP COLUMN disappear_secs')
        ..execute('ALTER TABLE local_messages DROP COLUMN expires_at')
        ..execute('ALTER TABLE local_chats DROP COLUMN disappear_secs')
        ..execute('ALTER TABLE local_chats DROP COLUMN disappear_changed_by')
        ..execute('ALTER TABLE local_chats DROP COLUMN disappear_changed_at')
        ..execute('ALTER TABLE local_chats DROP COLUMN disappear_changed_seq')
        ..execute('PRAGMA user_version = 3');
    }));
    addTearDown(db.close);
    expect((await db.chatById('C'))!.mutedUntil, isNull);
    await db.setMutedUntil('C', 5);
    expect((await db.chatById('C'))!.mutedUntil, 5);
  });

  test('schema 4 to 5: chats get a draft, empty for the chats already stored', () async {
    final dir = await Directory.systemTemp.createTemp('famchat_migration');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/chat.db');
    final fresh = ChatDb(NativeDatabase(file));
    await fresh.customSelect('SELECT 1').get();
    await fresh.close();

    final db = ChatDb(NativeDatabase(file, setup: (raw) {
      raw
        ..execute('ALTER TABLE local_chats DROP COLUMN draft')
        ..execute('ALTER TABLE local_users DROP COLUMN avatar_key')
        ..execute('ALTER TABLE local_users DROP COLUMN former')
        ..execute('ALTER TABLE local_chats DROP COLUMN family_id')
        ..execute('ALTER TABLE local_users DROP COLUMN family_ids')
        ..execute('ALTER TABLE local_chats DROP COLUMN pinned_at')
        ..execute('ALTER TABLE local_chats DROP COLUMN archived_at')
        ..execute('ALTER TABLE local_chats DROP COLUMN marked_unread')
        ..execute('ALTER TABLE local_chats DROP COLUMN avatar_key')
        ..execute('ALTER TABLE local_users DROP COLUMN last_seen_at')
        ..execute("INSERT INTO local_chats (id, kind, created_by, current_epoch, epoch_ready, last_seq, created_at) "
            "VALUES ('C', 'direct', 'A', 1, 1, 0, 0)")
        ..execute('DROP TABLE local_stars')
        ..execute('DROP TABLE local_scheduled')
        ..execute('DROP TABLE local_reminders')
        ..execute('ALTER TABLE local_messages DROP COLUMN scheduled_for')
        ..execute('DROP INDEX local_messages_expires_at')
        ..execute('ALTER TABLE local_messages DROP COLUMN disappear_secs')
        ..execute('ALTER TABLE local_messages DROP COLUMN expires_at')
        ..execute('ALTER TABLE local_chats DROP COLUMN disappear_secs')
        ..execute('ALTER TABLE local_chats DROP COLUMN disappear_changed_by')
        ..execute('ALTER TABLE local_chats DROP COLUMN disappear_changed_at')
        ..execute('ALTER TABLE local_chats DROP COLUMN disappear_changed_seq')
        ..execute('PRAGMA user_version = 4');
    }));
    addTearDown(db.close);
    expect((await db.chatById('C'))!.draft, isNull);
    await db.setDraft('C', 'half a thought');
    expect((await db.chatById('C'))!.draft, 'half a thought');
  });

  test('schema 5 to 6: users get a profile photo key, empty for the users already known', () async {
    final dir = await Directory.systemTemp.createTemp('famchat_migration');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/chat.db');
    final fresh = ChatDb(NativeDatabase(file));
    await fresh.customSelect('SELECT 1').get();
    await fresh.close();

    final db = ChatDb(NativeDatabase(file, setup: (raw) {
      raw
        ..execute('ALTER TABLE local_users DROP COLUMN avatar_key')
        ..execute('ALTER TABLE local_users DROP COLUMN former')
        ..execute('ALTER TABLE local_chats DROP COLUMN family_id')
        ..execute('ALTER TABLE local_users DROP COLUMN family_ids')
        ..execute('ALTER TABLE local_chats DROP COLUMN pinned_at')
        ..execute('ALTER TABLE local_chats DROP COLUMN archived_at')
        ..execute('ALTER TABLE local_chats DROP COLUMN marked_unread')
        ..execute('ALTER TABLE local_chats DROP COLUMN avatar_key')
        ..execute('ALTER TABLE local_users DROP COLUMN last_seen_at')
        ..execute("INSERT INTO local_users (id, name, is_admin, identity_pub, trusted_identity_pub) VALUES ('A', 'Ann', 1, 'k', 'k')")
        ..execute('DROP TABLE local_stars')
        ..execute('DROP TABLE local_scheduled')
        ..execute('DROP TABLE local_reminders')
        ..execute('ALTER TABLE local_messages DROP COLUMN scheduled_for')
        ..execute('DROP INDEX local_messages_expires_at')
        ..execute('ALTER TABLE local_messages DROP COLUMN disappear_secs')
        ..execute('ALTER TABLE local_messages DROP COLUMN expires_at')
        ..execute('ALTER TABLE local_chats DROP COLUMN disappear_secs')
        ..execute('ALTER TABLE local_chats DROP COLUMN disappear_changed_by')
        ..execute('ALTER TABLE local_chats DROP COLUMN disappear_changed_at')
        ..execute('ALTER TABLE local_chats DROP COLUMN disappear_changed_seq')
        ..execute('PRAGMA user_version = 5');
    }));
    addTearDown(db.close);
    expect((await db.userById('A'))!.avatarKey, isNull);
    await db.putUser((await db.userById('A'))!.copyWith(avatarKey: const Value('K1')));
    expect((await db.userById('A'))!.avatarKey, 'K1');
  });

  test('schema 6 to 7: users get a former flag, unset for the users already known', () async {
    final dir = await Directory.systemTemp.createTemp('famchat_migration');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/chat.db');
    final fresh = ChatDb(NativeDatabase(file));
    await fresh.customSelect('SELECT 1').get();
    await fresh.close();

    final db = ChatDb(NativeDatabase(file, setup: (raw) {
      raw
        ..execute('ALTER TABLE local_users DROP COLUMN former')
        ..execute('ALTER TABLE local_chats DROP COLUMN family_id')
        ..execute('ALTER TABLE local_users DROP COLUMN family_ids')
        ..execute('ALTER TABLE local_chats DROP COLUMN pinned_at')
        ..execute('ALTER TABLE local_chats DROP COLUMN archived_at')
        ..execute('ALTER TABLE local_chats DROP COLUMN marked_unread')
        ..execute('ALTER TABLE local_chats DROP COLUMN avatar_key')
        ..execute('ALTER TABLE local_users DROP COLUMN last_seen_at')
        ..execute("INSERT INTO local_users (id, name, is_admin, identity_pub, trusted_identity_pub) VALUES ('A', 'Ann', 1, 'k', 'k')")
        ..execute('DROP TABLE local_stars')
        ..execute('DROP TABLE local_scheduled')
        ..execute('DROP TABLE local_reminders')
        ..execute('ALTER TABLE local_messages DROP COLUMN scheduled_for')
        ..execute('DROP INDEX local_messages_expires_at')
        ..execute('ALTER TABLE local_messages DROP COLUMN disappear_secs')
        ..execute('ALTER TABLE local_messages DROP COLUMN expires_at')
        ..execute('ALTER TABLE local_chats DROP COLUMN disappear_secs')
        ..execute('ALTER TABLE local_chats DROP COLUMN disappear_changed_by')
        ..execute('ALTER TABLE local_chats DROP COLUMN disappear_changed_at')
        ..execute('ALTER TABLE local_chats DROP COLUMN disappear_changed_seq')
        ..execute('PRAGMA user_version = 6');
    }));
    addTearDown(db.close);
    expect((await db.userById('A'))!.former, isNull);
    await db.putUser((await db.userById('A'))!.copyWith(former: const Value(true)));
    expect((await db.userById('A'))!.former, isTrue);
  });

  /// A schema-7 database (no family pin tables), set up by [seed], opened as the current schema.
  Future<ChatDb> fromSchema7(void Function(dynamic raw) seed) async {
    final dir = await Directory.systemTemp.createTemp('famchat_migration');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/chat.db');
    final fresh = ChatDb(NativeDatabase(file));
    await fresh.customSelect('SELECT 1').get();
    await fresh.close();
    final db = ChatDb(NativeDatabase(file, setup: (raw) {
      raw
        ..execute('DROP TABLE local_families')
        ..execute('DROP TABLE local_family_admins')
        ..execute('DROP TABLE local_revoked_proofs')
        ..execute('ALTER TABLE local_chats DROP COLUMN family_id')
        ..execute('ALTER TABLE local_users DROP COLUMN family_ids')
        ..execute('ALTER TABLE local_chats DROP COLUMN pinned_at')
        ..execute('ALTER TABLE local_chats DROP COLUMN archived_at')
        ..execute('ALTER TABLE local_chats DROP COLUMN marked_unread')
        ..execute('ALTER TABLE local_chats DROP COLUMN avatar_key')
        ..execute('ALTER TABLE local_users DROP COLUMN last_seen_at')
        ..execute('DROP TABLE local_scheduled')
        ..execute('DROP TABLE local_reminders')
        ..execute('ALTER TABLE local_messages DROP COLUMN scheduled_for')
        ..execute('DROP INDEX local_messages_expires_at')
        ..execute('ALTER TABLE local_messages DROP COLUMN disappear_secs')
        ..execute('ALTER TABLE local_messages DROP COLUMN expires_at')
        ..execute('ALTER TABLE local_chats DROP COLUMN disappear_secs')
        ..execute('ALTER TABLE local_chats DROP COLUMN disappear_changed_by')
        ..execute('ALTER TABLE local_chats DROP COLUMN disappear_changed_at')
        ..execute('ALTER TABLE local_chats DROP COLUMN disappear_changed_seq');
      seed(raw);
      raw.execute('PRAGMA user_version = 7');
    }));
    addTearDown(db.close);
    return db;
  }

  test("schema 7 to 8: a device that pinned admins keeps them as family 1's", () async {
    final db = await fromSchema7((raw) => raw
      ..execute("INSERT INTO meta (key, value) VALUES ('adminsPinned', '1')")
      ..execute("INSERT INTO local_users (id, name, is_admin, identity_pub, trusted_identity_pub, pinned_admin) VALUES ('A', 'Ann', 1, 'k', 'k', 1)")
      ..execute("INSERT INTO local_users (id, name, is_admin, identity_pub, trusted_identity_pub, pinned_admin) VALUES ('B', 'Bo', 1, 'k2', 'k2', 0)")
      ..execute("INSERT INTO local_users (id, name, is_admin, identity_pub, trusted_identity_pub, pinned_admin) VALUES ('C', 'Cy', 0, 'k3', 'k3', 1)"));
    expect(await db.familyPins(), {
      1: {'A', 'C'},
    });
  });

  test('schema 7 to 8: a device that never pinned has seen no family', () async {
    final db = await fromSchema7((raw) => raw.execute(
        "INSERT INTO local_users (id, name, is_admin, identity_pub, trusted_identity_pub, pinned_admin) VALUES ('A', 'Ann', 1, 'k', 'k', 1)"));
    expect(await db.familyPins(), isEmpty);
  });

  test('schema 8 to 9: chats get a family id, users their family ids, pins a proof and revoked proofs a table; rows kept', () async {
    final dir = await Directory.systemTemp.createTemp('famchat_migration');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/chat.db');
    final fresh = ChatDb(NativeDatabase(file));
    await fresh.customSelect('SELECT 1').get();
    await fresh.close();

    final db = ChatDb(NativeDatabase(file, setup: (raw) {
      raw
        ..execute('ALTER TABLE local_chats DROP COLUMN family_id')
        ..execute('ALTER TABLE local_users DROP COLUMN family_ids')
        ..execute('ALTER TABLE local_chats DROP COLUMN pinned_at')
        ..execute('ALTER TABLE local_chats DROP COLUMN archived_at')
        ..execute('ALTER TABLE local_chats DROP COLUMN marked_unread')
        ..execute('ALTER TABLE local_chats DROP COLUMN avatar_key')
        ..execute('ALTER TABLE local_users DROP COLUMN last_seen_at')
        ..execute('ALTER TABLE local_family_admins DROP COLUMN proof_sig')
        ..execute('DROP TABLE local_revoked_proofs')
        ..execute("INSERT INTO local_families (id) VALUES (1)")
        ..execute("INSERT INTO local_family_admins (family_id, user_id) VALUES (1, 'A')")
        ..execute("INSERT INTO local_users (id, name, is_admin, identity_pub, trusted_identity_pub) VALUES ('A', 'Ann', 1, 'k', 'k')")
        ..execute("INSERT INTO local_chats (id, kind, title, created_by, current_epoch, epoch_ready, last_seq, created_at) "
            "VALUES ('C', 'group', 'Us', 'A', 1, 1, 4, 0)")
        ..execute('DROP TABLE local_stars')
        ..execute('DROP TABLE local_scheduled')
        ..execute('DROP TABLE local_reminders')
        ..execute('ALTER TABLE local_messages DROP COLUMN scheduled_for')
        ..execute('DROP INDEX local_messages_expires_at')
        ..execute('ALTER TABLE local_messages DROP COLUMN disappear_secs')
        ..execute('ALTER TABLE local_messages DROP COLUMN expires_at')
        ..execute('ALTER TABLE local_chats DROP COLUMN disappear_secs')
        ..execute('ALTER TABLE local_chats DROP COLUMN disappear_changed_by')
        ..execute('ALTER TABLE local_chats DROP COLUMN disappear_changed_at')
        ..execute('ALTER TABLE local_chats DROP COLUMN disappear_changed_seq')
        ..execute('PRAGMA user_version = 8');
    }));
    addTearDown(db.close);
    final user = (await db.userById('A'))!, chat = (await db.chatById('C'))!;
    expect(user.name, 'Ann');
    expect(user.familyIds, '[]');
    expect(chat.title, 'Us');
    expect(chat.lastSeq, 4);
    expect(chat.familyId, isNull);
    await db.putUser(user.copyWith(familyIds: '[1,2]'));
    expect((await db.userById('A'))!.familyIds, '[1,2]');
    // Pins kept; the revoked proofs table exists, and a dropped pin's last seen proof lands there.
    expect(await db.familyPins(), {
      1: {'A'},
    });
    expect(await db.revokedProofs(), isEmpty);
    await db.updateFamilyPins({
      1: {'A'},
    }, proofs: {
      1: {'A': 's1'},
    });
    await db.updateFamilyPins({1: {}});
    expect(await db.revokedProofs(), {(1, 'A', 's1')});
  });

  test('schema 9 to 10: chats get pin, archive, marked-unread and photo state, users a last seen time; rows kept', () async {
    final dir = await Directory.systemTemp.createTemp('famchat_migration');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/chat.db');
    final fresh = ChatDb(NativeDatabase(file));
    await fresh.customSelect('SELECT 1').get();
    await fresh.close();

    final db = ChatDb(NativeDatabase(file, setup: (raw) {
      raw
        ..execute('ALTER TABLE local_chats DROP COLUMN pinned_at')
        ..execute('ALTER TABLE local_chats DROP COLUMN archived_at')
        ..execute('ALTER TABLE local_chats DROP COLUMN marked_unread')
        ..execute('ALTER TABLE local_chats DROP COLUMN avatar_key')
        ..execute('ALTER TABLE local_users DROP COLUMN last_seen_at')
        ..execute("INSERT INTO local_users (id, name, is_admin, identity_pub, trusted_identity_pub) VALUES ('A', 'Ann', 1, 'k', 'k')")
        ..execute("INSERT INTO local_chats (id, kind, title, created_by, current_epoch, epoch_ready, last_seq, created_at) "
            "VALUES ('C', 'group', 'Us', 'A', 1, 1, 4, 0)")
        ..execute('DROP TABLE local_stars')
        ..execute('DROP TABLE local_scheduled')
        ..execute('DROP TABLE local_reminders')
        ..execute('ALTER TABLE local_messages DROP COLUMN scheduled_for')
        ..execute('DROP INDEX local_messages_expires_at')
        ..execute('ALTER TABLE local_messages DROP COLUMN disappear_secs')
        ..execute('ALTER TABLE local_messages DROP COLUMN expires_at')
        ..execute('ALTER TABLE local_chats DROP COLUMN disappear_secs')
        ..execute('ALTER TABLE local_chats DROP COLUMN disappear_changed_by')
        ..execute('ALTER TABLE local_chats DROP COLUMN disappear_changed_at')
        ..execute('ALTER TABLE local_chats DROP COLUMN disappear_changed_seq')
        ..execute('PRAGMA user_version = 9');
    }));
    addTearDown(db.close);
    final chat = (await db.chatById('C'))!;
    expect(chat.title, 'Us');
    expect(chat.pinnedAt, isNull);
    expect(chat.archivedAt, isNull);
    expect(chat.markedUnread, isFalse);
    expect(chat.avatarKey, isNull);
    expect((await db.userById('A'))!.lastSeenAt, isNull);
    await db.setChatState('C', pinnedAt: const Value(5), markedUnread: true);
    await db.setLastSeen('A', 7);
    expect((await db.chatById('C'))!.pinnedAt, 5);
    expect((await db.chatById('C'))!.markedUnread, isTrue);
    expect((await db.userById('A'))!.lastSeenAt, 7);
  });

  test('schema 10 to 11: a table for starred messages; rows kept', () async {
    final dir = await Directory.systemTemp.createTemp('famchat_migration');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/chat.db');
    final fresh = ChatDb(NativeDatabase(file));
    await fresh.customSelect('SELECT 1').get();
    await fresh.close();

    final db = ChatDb(NativeDatabase(file, setup: (raw) {
      raw
        ..execute('DROP TABLE local_stars')
        ..execute("INSERT INTO local_chats (id, kind, title, created_by, current_epoch, epoch_ready, last_seq, created_at) "
            "VALUES ('C', 'group', 'Us', 'A', 1, 1, 4, 0)")
        ..execute('DROP TABLE local_scheduled')
        ..execute('DROP TABLE local_reminders')
        ..execute('ALTER TABLE local_messages DROP COLUMN scheduled_for')
        ..execute('DROP INDEX local_messages_expires_at')
        ..execute('ALTER TABLE local_messages DROP COLUMN disappear_secs')
        ..execute('ALTER TABLE local_messages DROP COLUMN expires_at')
        ..execute('ALTER TABLE local_chats DROP COLUMN disappear_secs')
        ..execute('ALTER TABLE local_chats DROP COLUMN disappear_changed_by')
        ..execute('ALTER TABLE local_chats DROP COLUMN disappear_changed_at')
        ..execute('ALTER TABLE local_chats DROP COLUMN disappear_changed_seq')
        ..execute('PRAGMA user_version = 10');
    }));
    addTearDown(db.close);
    expect((await db.chatById('C'))!.title, 'Us');
    expect(await db.watchStars().first, isEmpty);
    await db.setStar('C', 'M', starred: true, at: 3);
    expect((await db.watchStars(chatId: 'C').first).single.messageId, 'M');
  });

  test('schema 11 to 12: disappearing timers on chats and messages, and an expiry index; rows kept', () async {
    final dir = await Directory.systemTemp.createTemp('famchat_migration');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/chat.db');
    final fresh = ChatDb(NativeDatabase(file));
    await fresh.customSelect('SELECT 1').get();
    await fresh.close();

    final db = ChatDb(NativeDatabase(file, setup: (raw) {
      raw
        ..execute('DROP TABLE local_scheduled')
        ..execute('DROP TABLE local_reminders')
        ..execute('ALTER TABLE local_messages DROP COLUMN scheduled_for')
        ..execute('DROP INDEX local_messages_expires_at')
        ..execute('ALTER TABLE local_messages DROP COLUMN disappear_secs')
        ..execute('ALTER TABLE local_messages DROP COLUMN expires_at')
        ..execute('ALTER TABLE local_chats DROP COLUMN disappear_secs')
        ..execute('ALTER TABLE local_chats DROP COLUMN disappear_changed_by')
        ..execute('ALTER TABLE local_chats DROP COLUMN disappear_changed_at')
        ..execute('ALTER TABLE local_chats DROP COLUMN disappear_changed_seq')
        ..execute("INSERT INTO local_chats (id, kind, title, created_by, current_epoch, epoch_ready, last_seq, created_at) "
            "VALUES ('C', 'group', 'Us', 'A', 1, 1, 4, 0)")
        ..execute("INSERT INTO local_messages (id, chat_id, seq, sender_user_id, sender_device_id, kind, body, created_at, state) "
            "VALUES ('M', 'C', 4, 'B', 'D', 'text', '{}', 5, 'sent')")
        ..execute('PRAGMA user_version = 11');
    }));
    addTearDown(db.close);
    db.myUserId = 'A';
    final chat = (await db.chatById('C'))!;
    expect(chat.title, 'Us');
    expect(chat.disappearSecs, isNull);
    expect(chat.disappearChangedSeq, isNull);
    final m = (await db.messageById('M'))!;
    expect((m.disappearSecs, m.expiresAt), (null, null), reason: 'messages stored before carry no timer');
    expect(await db.nextExpiry(), isNull);
    final indexes = await db.customSelect("SELECT name FROM sqlite_master WHERE type = 'index' AND name = 'local_messages_expires_at'").get();
    expect(indexes, hasLength(1));
  });

  test('schema 12 to 13: scheduled messages and reminders get tables, messages a late mark; rows kept', () async {
    final dir = await Directory.systemTemp.createTemp('famchat_migration');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/chat.db');
    final fresh = ChatDb(NativeDatabase(file));
    await fresh.customSelect('SELECT 1').get();
    await fresh.close();

    final db = ChatDb(NativeDatabase(file, setup: (raw) {
      raw
        ..execute('DROP TABLE local_scheduled')
        ..execute('DROP TABLE local_reminders')
        ..execute('ALTER TABLE local_messages DROP COLUMN scheduled_for')
        ..execute("INSERT INTO local_chats (id, kind, title, created_by, current_epoch, epoch_ready, last_seq, created_at) "
            "VALUES ('C', 'group', 'Us', 'A', 1, 1, 4, 0)")
        ..execute("INSERT INTO local_messages (id, chat_id, seq, sender_user_id, sender_device_id, kind, body, created_at, state) "
            "VALUES ('M', 'C', 4, 'B', 'D', 'text', '{}', 5, 'sent')")
        ..execute('PRAGMA user_version = 12');
    }));
    addTearDown(db.close);
    expect((await db.messageById('M'))!.scheduledFor, isNull);
    expect(await db.allScheduled(), isEmpty);
    await db.putScheduled(const ScheduledRow(
      id: 'S',
      chatId: 'C',
      kind: 'text',
      body: '{}',
      envelope: null,
      deliverAt: 9,
      state: 'local',
      onServer: false,
      senderDeviceId: 'D',
      createdAt: 1,
      updatedAt: 1,
    ));
    expect((await db.scheduledToSubmit()).map((r) => r.id), ['S']);
    await db.putReminder('C', 'M', 7);
    expect((await db.watchReminders('C').first), {'M': 7});
    await db.deleteChat('C');
    expect(await db.allScheduled(), isEmpty, reason: 'a chat that goes takes its scheduled messages');
    expect(await db.allReminders(), isEmpty, reason: 'and its reminders');
  });

  test('family pins: replaced as a whole, families absent from the map are dropped', () async {
    final db = ChatDb(NativeDatabase.memory());
    addTearDown(db.close);
    expect(await db.familyPins(), isEmpty);
    await db.replaceFamilyPins({
      1: {'A'},
      2: {},
      3: {'B', 'C'},
    });
    expect(await db.familyPins(), {
      1: {'A'},
      2: <String>{},
      3: {'B', 'C'},
    });
    await db.replaceFamilyPins({
      2: {'D'},
    });
    expect(await db.familyPins(), {
      2: {'D'},
    });
  });

  test('family pins: an update overwrites only the families it names, the rest stay seen and frozen', () async {
    final db = ChatDb(NativeDatabase.memory());
    addTearDown(db.close);
    await db.updateFamilyPins({
      1: {'A'},
      2: {'B', 'C'},
    });
    await db.updateFamilyPins({
      2: {'C'},
      3: {},
    });
    expect(await db.familyPins(), {
      1: {'A'},
      2: {'C'},
      3: <String>{},
    });
    await db.updateFamilyPins({});
    expect(await db.familyPins(), {
      1: {'A'},
      2: {'C'},
      3: <String>{},
    });
  });
}
