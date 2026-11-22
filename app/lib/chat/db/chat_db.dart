// The device's local chat store (drift): the UI reads only from here. Plaintext of decrypted messages
// and chat keys live here; the database belongs to one signed-in device (see [ChatDb.bindDevice]).
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import '../wire.dart';

part 'chat_db.g.dart';

@DataClassName('ChatRow')
class LocalChats extends Table {
  TextColumn get id => text()();
  TextColumn get kind => text()();
  TextColumn get title => text().nullable()();
  TextColumn get createdBy => text()();
  IntColumn get currentEpoch => integer()();
  BoolColumn get epochReady => boolean()();
  IntColumn get lastSeq => integer()();
  IntColumn get lastMessageAt => integer().nullable()();
  IntColumn get createdAt => integer()();
  IntColumn get myLastReadSeq => integer().withDefault(const Constant(0))();

  /// This user's mute (Unix ms; see [ChatDto.mutedUntil]), or null.
  IntColumn get mutedUntil => integer().nullable()();

  /// Text typed here and not sent yet (this device only), or null.
  TextColumn get draft => text().nullable()();

  /// A group's family (see [ChatDto.familyId]); null for direct chats.
  IntColumn get familyId => integer().nullable()();

  /// Every message with seq ≤ this is stored locally (the `after=` cursor).
  IntColumn get syncedSeq => integer().withDefault(const Constant(0))();

  /// This user's pin (Unix ms; see [ChatDto.pinnedAt]), or null.
  IntColumn get pinnedAt => integer().nullable()();

  /// When this user archived the chat (Unix ms; see [ChatDto.archivedAt]), or null.
  IntColumn get archivedAt => integer().nullable()();

  /// This user marked the chat as unread (see [ChatDto.markedUnread]).
  BoolColumn get markedUnread => boolean().withDefault(const Constant(false))();

  /// A group's photo key (see [ChatDto.avatarKey]), or null.
  TextColumn get avatarKey => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('MemberRow')
class LocalMembers extends Table {
  TextColumn get chatId => text()();
  TextColumn get userId => text()();
  IntColumn get joinedSeq => integer()();
  IntColumn get lastReadSeq => integer()();

  @override
  Set<Column> get primaryKey => {chatId, userId};
}

/// Messages, including this device's outbox (`state == 'pending'`, `seq == null`).
@DataClassName('MessageRow')
@TableIndex(name: 'local_messages_chat_seq', columns: {#chatId, #seq})
class LocalMessages extends Table {
  TextColumn get id => text()();
  TextColumn get chatId => text()();
  IntColumn get seq => integer().nullable()();
  TextColumn get senderUserId => text()();
  TextColumn get senderDeviceId => text()();

  /// text | photo | voice | gif | video | game | move | reaction | edit | delete | unknown | undecryptable | invalid
  TextColumn get kind => text()();

  /// The plaintext JSON (null while undecryptable).
  TextColumn get body => text().nullable()();

  /// For reactions, edits and deletes: the message they change. For moves: the game's `game` message.
  TextColumn get targetId => text().nullable()();

  /// The envelope JSON, kept only while the message can't be decrypted yet.
  TextColumn get envelope => text().nullable()();
  IntColumn get createdAt => integer()();

  /// pending | sent | failed
  TextColumn get state => text()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('KeyRow')
class LocalKeys extends Table {
  TextColumn get chatId => text()();
  IntColumn get epoch => integer()();
  BlobColumn get key => blob()();

  @override
  Set<Column> get primaryKey => {chatId, epoch};
}

/// This user's starred messages (docs/protocol.md "Starred messages"), mirrored from the server.
/// [pending]: changed here and not yet confirmed by the server; [starred] false is an unstar waiting
/// to go (the row goes once it does).
@DataClassName('StarRow')
class LocalStars extends Table {
  TextColumn get messageId => text()();
  TextColumn get chatId => text()();
  IntColumn get starredAt => integer()();
  BoolColumn get starred => boolean().withDefault(const Constant(true))();
  BoolColumn get pending => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {messageId};
}

@DataClassName('UserRow')
class LocalUsers extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  BoolColumn get isAdmin => boolean()();

  /// The identity key the server lists now.
  TextColumn get identityPub => text()();

  /// The key first seen (or last acknowledged). Differs from [identityPub] after a change.
  TextColumn get trustedIdentityPub => text()();

  /// JSON list of every key this device has trusted for the user (first seen and acknowledged),
  /// so devices certified by an earlier key still verify their old messages.
  TextColumn get knownIdentityPubs => text().withDefault(const Constant('[]'))();

  /// This device trusts the user as an admin of some family (see [LocalFamilyAdmins]; kept in step
  /// with it by the directory). The server's [isAdmin] alone doesn't make anyone's reset count.
  BoolColumn get pinnedAdmin => boolean().withDefault(const Constant(false))();

  /// The account was deleted (docs/protocol.md "Deleting an account"): kept so old messages and
  /// certificates still resolve, but not offered for new chats. Null means not deleted.
  BoolColumn get deleted => boolean().nullable()();

  /// Someone I only share a chat with, not a family (multi-family). Null means not former.
  BoolColumn get former => boolean().nullable()();

  /// Their profile photo's key (see [UserDto.avatarKey]), or null.
  TextColumn get avatarKey => text().nullable()();

  /// JSON list of the ids of the families they share with this user, ascending; empty for former users.
  TextColumn get familyIds => text().withDefault(const Constant('[]'))();

  /// When they were last online (Unix ms; see [UserDto.lastSeenAt]), or null.
  IntColumn get lastSeenAt => integer().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('DeviceRow')
class LocalDevices extends Table {
  TextColumn get id => text()();
  TextColumn get userId => text()();
  TextColumn get name => text()();
  TextColumn get encPub => text()();
  TextColumn get signPub => text()();
  TextColumn get certSig => text()();
  BoolColumn get revoked => boolean()();

  /// The cert verifies against the user's current identity key or a key trusted earlier.
  BoolColumn get certValid => boolean()();

  /// The cert verifies against a key this device trusts (not an unacknowledged new one). Only
  /// trusted devices get wraps, count as wrappers, or count as senders.
  BoolColumn get trusted => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Verified account resets this device saw happen (lib/chat/resets.dart "witnessed"): each shows a
/// banner in every chat shared with the reset user until dismissed there.
@DataClassName('ResetRow')
class LocalResets extends Table {
  TextColumn get id => text()();
  TextColumn get userId => text()();
  TextColumn get signerUserId => text()();

  /// `admin` or `recovery`.
  TextColumn get signerKind => text()();
  IntColumn get createdAt => integer()();

  /// JSON list of chat ids where the banner was dismissed.
  TextColumn get dismissedChats => text().withDefault(const Constant('[]'))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Families this device has seen and pinned admins for (lib/chat/resets.dart): a family absent here
/// is seen for the first time at the next directory refresh. A directory refresh never removes a
/// row, so the server can't make a family new again.
@DataClassName('FamilyRow')
class LocalFamilies extends Table {
  IntColumn get id => integer()();

  @override
  Set<Column> get primaryKey => {id};
}

/// The users this device trusts as admins of each family in [LocalFamilies]: pinned when it first
/// saw the family (or from a pairing handover), or promoted by an admin it trusts there.
@DataClassName('FamilyAdminRow')
class LocalFamilyAdmins extends Table {
  IntColumn get familyId => integer()();
  TextColumn get userId => text()();

  /// The `sig` of their valid promotion proof for this family as last seen, or null: revoked (see
  /// [LocalRevokedProofs]) when the pin is dropped or a different proof replaces it.
  TextColumn get proofSig => text().nullable()();

  @override
  Set<Column> get primaryKey => {familyId, userId};
}

/// Promotion proofs that never make their user an admin of their family again on this device: the
/// last seen proof of an admin the directory unpinned (demoted, removed or gone), and any proof a
/// pinned admin's newer one replaced. Becoming trusted again needs a different, fresh proof.
@DataClassName('RevokedProofRow')
class LocalRevokedProofs extends Table {
  IntColumn get familyId => integer()();
  TextColumn get userId => text()();
  TextColumn get sig => text()();

  @override
  Set<Column> get primaryKey => {familyId, userId, sig};
}

@DataClassName('MetaRow')
class Meta extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}

class ChatListItem {
  const ChatListItem({
    required this.chat,
    required this.members,
    required this.last,
    required this.unread,
    this.lastChanges = const [],
  });
  final ChatRow chat;
  final List<MemberRow> members;

  /// The newest message that isn't a change to another (a reaction, edit or delete).
  final MessageRow? last;

  /// The edits and deletes of [last] (and its reactions), in order.
  final List<MessageRow> lastChanges;
  final int unread;

  int get activity => [chat.createdAt, chat.lastMessageAt ?? 0, last?.createdAt ?? 0].reduce((a, b) => a > b ? a : b);

  /// In the Archive: archived, and nothing newer since (a muted chat stays archived whatever comes).
  bool archivedAt(DateTime now) {
    final at = chat.archivedAt;
    if (at == null) return false;
    return (chat.mutedUntil ?? 0) > now.millisecondsSinceEpoch || activity <= at;
  }

  bool get pinned => chat.pinnedAt != null;

  /// Shown as unread: unread messages, or marked as unread.
  bool get looksUnread => unread > 0 || chat.markedUnread;
}

/// Pinned chats first (newest pin first), then newest activity first.
int compareChatListItems(ChatListItem a, ChatListItem b) {
  final pa = a.chat.pinnedAt, pb = b.chat.pinnedAt;
  if (pa != null || pb != null) {
    if (pa == null) return 1;
    if (pb == null) return -1;
    if (pa != pb) return pb.compareTo(pa);
  }
  return b.activity.compareTo(a.activity);
}

@DriftDatabase(tables: [
  LocalChats,
  LocalMembers,
  LocalMessages,
  LocalKeys,
  LocalUsers,
  LocalDevices,
  LocalResets,
  LocalFamilies,
  LocalFamilyAdmins,
  LocalRevokedProofs,
  LocalStars,
  Meta,
])
class ChatDb extends _$ChatDb {
  ChatDb(super.e);

  @override
  int get schemaVersion => 11;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onUpgrade: (m, from, to) async {
          if (from < 2) {
            await m.createTable(localResets);
            await m.addColumn(localUsers, localUsers.pinnedAdmin);
            // A device that already knew the family pins the admins it knew.
            await customStatement('UPDATE local_users SET pinned_admin = is_admin');
            await into(meta).insertOnConflictUpdate(const MetaRow(key: adminsPinnedKey, value: '1'));
          }
          if (from < 3) await m.addColumn(localUsers, localUsers.deleted);
          if (from < 4) await m.addColumn(localChats, localChats.mutedUntil);
          if (from < 5) await m.addColumn(localChats, localChats.draft);
          if (from < 6) await m.addColumn(localUsers, localUsers.avatarKey);
          if (from < 7) await m.addColumn(localUsers, localUsers.former);
          if (from < 8) {
            await m.createTable(localFamilies);
            await m.createTable(localFamilyAdmins);
            // The admins pinned before families existed are family 1's.
            if (await metaValue(adminsPinnedKey) != null) {
              await customStatement('INSERT OR IGNORE INTO local_families (id) VALUES (1)');
              await customStatement(
                  'INSERT OR IGNORE INTO local_family_admins (family_id, user_id) SELECT 1, id FROM local_users WHERE pinned_admin = 1');
            }
          }
          if (from < 9) {
            // Filled in by the next chat sync and directory refresh.
            await m.addColumn(localChats, localChats.familyId);
            await m.addColumn(localUsers, localUsers.familyIds);
            // Made with its proof column above when coming from before schema 8.
            if (from == 8) await m.addColumn(localFamilyAdmins, localFamilyAdmins.proofSig);
            await m.createTable(localRevokedProofs);
          }
          if (from < 10) {
            // Filled in by the next chat sync and directory refresh.
            await m.addColumn(localChats, localChats.pinnedAt);
            await m.addColumn(localChats, localChats.archivedAt);
            await m.addColumn(localChats, localChats.markedUnread);
            await m.addColumn(localChats, localChats.avatarKey);
            await m.addColumn(localUsers, localUsers.lastSeenAt);
          }
          // Filled in by the next sync.
          if (from < 11) await m.createTable(localStars);
        },
      );

  // ---------------------------------------------------------------------------------------------
  // Stars

  /// Starred message ids (in [chatId], or all), newest star first. Unstars waiting to go are left out.
  Stream<List<StarRow>> watchStars({String? chatId}) => (select(localStars)
        ..where((s) => s.starred.equals(true) & (chatId == null ? const Constant(true) : s.chatId.equals(chatId)))
        ..orderBy([(s) => OrderingTerm.desc(s.starredAt), (s) => OrderingTerm.desc(s.messageId)]))
      .watch();

  /// My starred messages that are here (in [chatId], or all), newest star first.
  Stream<List<MessageRow>> watchStarredMessages({String? chatId}) {
    final q = select(localMessages).join([innerJoin(localStars, localStars.messageId.equalsExp(localMessages.id))])
      ..where(localStars.starred.equals(true) & (chatId == null ? const Constant(true) : localMessages.chatId.equals(chatId)))
      ..orderBy([OrderingTerm.desc(localStars.starredAt), OrderingTerm.desc(localStars.messageId)]);
    return q.watch().map((rows) => [for (final r in rows) r.readTable(localMessages)]);
  }

  /// Stars or unstars here first; [pending] until the server has it.
  Future<void> setStar(String chatId, String messageId, {required bool starred, required int at, bool pending = true}) =>
      into(localStars).insertOnConflictUpdate(
          StarRow(messageId: messageId, chatId: chatId, starredAt: at, starred: starred, pending: pending));

  Future<List<StarRow>> pendingStars() => (select(localStars)..where((s) => s.pending.equals(true))).get();

  Future<StarRow?> starOf(String messageId) =>
      (select(localStars)..where((s) => s.messageId.equals(messageId))).getSingleOrNull();

  Future<void> dropStar(String messageId) => (delete(localStars)..where((s) => s.messageId.equals(messageId))).go();

  /// The server's list replaces what's here, except changes still waiting to go.
  Future<void> replaceStars(List<({String chatId, String messageId, int starredAt})> stars) => transaction(() async {
        await (delete(localStars)..where((s) => s.pending.equals(false))).go();
        for (final st in stars) {
          await into(localStars).insert(
            StarRow(messageId: st.messageId, chatId: st.chatId, starredAt: st.starredAt, starred: true, pending: false),
            mode: InsertMode.insertOrIgnore,
          );
        }
      });

  /// Set once a device before schema 8 had pinned the family's admins (the upgrade to per-family
  /// pins reads it).
  static const adminsPinnedKey = 'adminsPinned';

  Future<String?> metaValue(String key) async =>
      (await (select(meta)..where((m) => m.key.equals(key))).getSingleOrNull())?.value;

  Future<void> setMeta(String key, String value) => into(meta).insertOnConflictUpdate(MetaRow(key: key, value: value));

  // --- device binding ---

  /// Ties the database to [deviceId]; if it belonged to another device (a previous sign-in), wipes it.
  Future<void> bindDevice(String deviceId) => transaction(() async {
        final row = await (select(meta)..where((m) => m.key.equals('deviceId'))).getSingleOrNull();
        if (row?.value == deviceId) return;
        for (final t in allTables) {
          await delete(t).go();
        }
        await into(meta).insert(MetaRow(key: 'deviceId', value: deviceId));
      });

  /// Deletes everything (sign-out).
  Future<void> wipe() => transaction(() async {
        for (final t in allTables) {
          await delete(t).go();
        }
      });

  // --- chats ---

  /// Inserts or updates a chat from the server and replaces its member list; keeps local sync state.
  Future<void> upsertChat(ChatDto c) => transaction(() async {
        await into(localChats).insert(
          LocalChatsCompanion.insert(
            id: c.id,
            kind: c.kind,
            title: Value(c.title),
            createdBy: c.createdBy,
            currentEpoch: c.currentEpoch,
            epochReady: c.epochReady,
            lastSeq: c.lastSeq,
            lastMessageAt: Value(c.lastMessageAt),
            createdAt: c.createdAt,
            mutedUntil: Value(c.mutedUntil),
            familyId: Value(c.familyId),
            pinnedAt: Value(c.pinnedAt),
            archivedAt: Value(c.archivedAt),
            markedUnread: Value(c.markedUnread),
            avatarKey: Value(c.avatarKey),
          ),
          onConflict: DoUpdate((_) => LocalChatsCompanion(
                kind: Value(c.kind),
                title: Value(c.title),
                createdBy: Value(c.createdBy),
                currentEpoch: Value(c.currentEpoch),
                epochReady: Value(c.epochReady),
                lastSeq: Value(c.lastSeq),
                lastMessageAt: Value(c.lastMessageAt),
                mutedUntil: Value(c.mutedUntil),
                familyId: Value(c.familyId),
                pinnedAt: Value(c.pinnedAt),
                archivedAt: Value(c.archivedAt),
                markedUnread: Value(c.markedUnread),
                avatarKey: Value(c.avatarKey),
              )),
        );
        await (delete(localMembers)..where((m) => m.chatId.equals(c.id))).go();
        await batch((b) => b.insertAll(localMembers, [
              for (final m in c.members)
                MemberRow(chatId: c.id, userId: m.userId, joinedSeq: m.joinedSeq, lastReadSeq: m.lastReadSeq),
            ]));
        final me = c.members.where((m) => m.userId == _myUserId).firstOrNull;
        if (me != null) {
          await (update(localChats)..where((t) => t.id.equals(c.id) & t.myLastReadSeq.isSmallerThanValue(me.lastReadSeq)))
              .write(LocalChatsCompanion(myLastReadSeq: Value(me.lastReadSeq)));
        }
      });

  String? _myUserId;

  /// Lets [upsertChat] take this user's read position from the server's member list.
  set myUserId(String id) => _myUserId = id;

  Future<ChatRow?> chatById(String id) => (select(localChats)..where((c) => c.id.equals(id))).getSingleOrNull();

  Future<List<ChatRow>> allChats() => select(localChats).get();

  Future<List<MemberRow>> membersOf(String chatId) =>
      (select(localMembers)..where((m) => m.chatId.equals(chatId))).get();

  Future<void> deleteChat(String id) => transaction(() async {
        await (delete(localMessages)..where((m) => m.chatId.equals(id))).go();
        await (delete(localMembers)..where((m) => m.chatId.equals(id))).go();
        await (delete(localKeys)..where((m) => m.chatId.equals(id))).go();
        await (delete(localChats)..where((m) => m.id.equals(id))).go();
      });

  Future<void> setSyncedSeq(String chatId, int seq) =>
      (update(localChats)..where((c) => c.id.equals(chatId))).write(LocalChatsCompanion(syncedSeq: Value(seq)));

  Future<void> setMyLastRead(String chatId, int seq) => (update(localChats)
        ..where((c) => c.id.equals(chatId) & c.myLastReadSeq.isSmallerThanValue(seq)))
      .write(LocalChatsCompanion(myLastReadSeq: Value(seq)));

  Future<void> setMemberRead(String chatId, String userId, int seq) => (update(localMembers)
        ..where((m) => m.chatId.equals(chatId) & m.userId.equals(userId) & m.lastReadSeq.isSmallerThanValue(seq)))
      .write(LocalMembersCompanion(lastReadSeq: Value(seq)));

  /// After a message with [seq] at [at] arrived.
  Future<void> noteActivity(String chatId, int seq, int at) => customUpdate(
        'UPDATE local_chats SET last_seq = MAX(last_seq, ?), last_message_at = MAX(COALESCE(last_message_at, 0), ?) WHERE id = ?',
        variables: [Variable.withInt(seq), Variable.withInt(at), Variable.withString(chatId)],
        updates: {localChats},
      );

  // --- messages ---

  /// False if a message with this id is already stored.
  Future<bool> insertMessageIfAbsent(MessageRow m) => transaction(() async {
        if (await messageById(m.id) != null) return false;
        await into(localMessages).insert(m);
        return true;
      });

  Future<void> deleteMessages(List<String> ids) => (delete(localMessages)..where((m) => m.id.isIn(ids))).go();

  Future<MessageRow?> messageById(String id) =>
      (select(localMessages)..where((m) => m.id.equals(id))).getSingleOrNull();

  /// Overwrites every column, nulls included.
  Future<void> replaceMessage(MessageRow m) => into(localMessages).insertOnConflictUpdate(m.toCompanion(false));

  Future<void> ackMessage(String id, {required int seq, required int createdAt}) =>
      (update(localMessages)..where((m) => m.id.equals(id))).write(
        LocalMessagesCompanion(seq: Value(seq), createdAt: Value(createdAt), state: const Value('sent')),
      );

  Future<void> setMessageState(String id, String state) =>
      (update(localMessages)..where((m) => m.id.equals(id))).write(LocalMessagesCompanion(state: Value(state)));

  /// This device's unsent messages in creation order (ids are monotonic ULIDs).
  Future<List<MessageRow>> pendingOutbox(String deviceId) => (select(localMessages)
        ..where((m) => m.senderDeviceId.equals(deviceId) & m.state.equals('pending'))
        ..orderBy([(m) => OrderingTerm(expression: m.id)]))
      .get();

  Future<List<MessageRow>> undecryptable() =>
      (select(localMessages)..where((m) => m.kind.equals('undecryptable'))).get();

  /// Messages stored with a kind an older version didn't know.
  Future<List<MessageRow>> unknownKind() => (select(localMessages)..where((m) => m.kind.equals('unknown'))).get();

  /// Newest stored seq in a chat.
  Future<int?> maxSeq(String chatId) async {
    final q = selectOnly(localMessages)
      ..addColumns([localMessages.seq.max()])
      ..where(localMessages.chatId.equals(chatId));
    return (await q.getSingle()).read(localMessages.seq.max());
  }

  /// Sent messages by seq, then the outbox by creation time.
  Stream<List<MessageRow>> watchMessages(String chatId) => (select(localMessages)
        ..where((m) => m.chatId.equals(chatId))
        ..orderBy([
          (m) => OrderingTerm(expression: m.seq.isNull()),
          (m) => OrderingTerm(expression: m.seq),
          (m) => OrderingTerm(expression: m.createdAt),
          (m) => OrderingTerm(expression: m.id),
        ]))
      .watch();

  Stream<ChatRow?> watchChat(String id) => (select(localChats)..where((c) => c.id.equals(id))).watchSingleOrNull();

  Stream<List<MemberRow>> watchMembers(String chatId) =>
      (select(localMembers)..where((m) => m.chatId.equals(chatId))).watch();

  static const _changeKinds = ['reaction', 'edit', 'delete', 'pin', 'vote', 'poll_end'];

  /// Keeps [text] as [chatId]'s draft; blank text clears it.
  Future<void> setDraft(String chatId, String? text) => (update(localChats)..where((c) => c.id.equals(chatId)))
      .write(LocalChatsCompanion(draft: Value(text == null || text.trim().isEmpty ? null : text)));

  Future<String?> draftOf(String chatId) async => (await chatById(chatId))?.draft;

  Future<void> setMutedUntil(String chatId, int? until) =>
      (update(localChats)..where((c) => c.id.equals(chatId))).write(LocalChatsCompanion(mutedUntil: Value(until)));

  /// This user's chat list state, as the server now has it (null arguments stay as they are).
  Future<void> setChatState(String chatId, {Value<int?> pinnedAt = const Value.absent(), Value<int?> archivedAt = const Value.absent(), bool? markedUnread}) =>
      (update(localChats)..where((c) => c.id.equals(chatId))).write(LocalChatsCompanion(
        pinnedAt: pinnedAt,
        archivedAt: archivedAt,
        markedUnread: markedUnread == null ? const Value.absent() : Value(markedUnread),
      ));

  Future<void> setChatTitle(String chatId, String title) =>
      (update(localChats)..where((c) => c.id.equals(chatId))).write(LocalChatsCompanion(title: Value(title)));

  Future<void> setChatAvatarKey(String chatId, String? key) =>
      (update(localChats)..where((c) => c.id.equals(chatId))).write(LocalChatsCompanion(avatarKey: Value(key)));

  /// [userId] went offline at [at] (a `presence` frame).
  Future<void> setLastSeen(String userId, int at) =>
      (update(localUsers)..where((u) => u.id.equals(userId))).write(LocalUsersCompanion(lastSeenAt: Value(at)));

  /// Every row in [chatId] that changes [targetId] (its reactions, edits and deletes), in order.
  Future<List<MessageRow>> changesTo(String chatId, String targetId) => (select(localMessages)
        ..where((m) => m.chatId.equals(chatId) & m.targetId.equals(targetId))
        ..orderBy([
          (m) => OrderingTerm(expression: m.seq.isNull()),
          (m) => OrderingTerm(expression: m.seq),
          (m) => OrderingTerm(expression: m.id),
        ]))
      .get();

  /// Text messages and polls (newest first, at most [limit]) whose text (a poll's question or an
  /// option) or one of their sender's edits matches
  /// the LIKE [pattern] (escaped with `\`). Callers check the latest text themselves.
  Future<List<MessageRow>> searchCandidates(String pattern, {String? chatId, int limit = 300}) async {
    final rows = await customSelect(
      "SELECT * FROM local_messages m WHERE m.kind IN ('text', 'photo', 'video', 'poll') AND (? IS NULL OR m.chat_id = ?) AND ("
      "coalesce(json_extract(m.body, '\$.text'), json_extract(m.body, '\$.caption'), json_extract(m.body, '\$.question')) LIKE ? ESCAPE '\\' "
      "OR (m.kind = 'poll' AND json_valid(m.body) AND EXISTS (SELECT 1 FROM json_each(m.body, '\$.options') o WHERE o.value LIKE ? ESCAPE '\\')) "
      "OR EXISTS (SELECT 1 FROM local_messages e "
      "WHERE e.kind = 'edit' AND e.target_id = m.id AND e.sender_user_id = m.sender_user_id "
      "AND json_extract(e.body, '\$.text') LIKE ? ESCAPE '\\')) "
      'ORDER BY m.created_at DESC, m.id DESC LIMIT ?',
      variables: [
        Variable<String>(chatId),
        Variable<String>(chatId),
        Variable.withString(pattern),
        Variable.withString(pattern),
        Variable.withString(pattern),
        Variable.withInt(limit),
      ],
      readsFrom: {localMessages},
    ).get();
    return [for (final r in rows) localMessages.map(r.data)];
  }

  /// Chats with members, last message and unread count (others' messages, not changes, above my read
  /// position and my join point), newest activity first.
  Stream<List<ChatListItem>> watchChatList(String myUserId) => customSelect(
        'SELECT 1',
        readsFrom: {localChats, localMembers, localMessages},
      ).watch().asyncMap((_) => _chatList(myUserId));

  Future<List<ChatListItem>> _chatList(String me) async {
    final chats = await select(localChats).get();
    final members = await select(localMembers).get();
    final items = <ChatListItem>[];
    for (final c in chats) {
      final last = await (select(localMessages)
            ..where((m) => m.chatId.equals(c.id) & m.kind.isIn(_changeKinds).not())
            ..orderBy([
              (m) => OrderingTerm(expression: m.seq.isNull(), mode: OrderingMode.desc),
              (m) => OrderingTerm(expression: m.seq, mode: OrderingMode.desc),
              (m) => OrderingTerm(expression: m.createdAt, mode: OrderingMode.desc),
            ])
            ..limit(1))
          .getSingleOrNull();
      final unread = await customSelect(
        // Counted from where I joined: history from before is shown, not unread.
        "SELECT COUNT(*) AS n FROM local_messages m WHERE chat_id = ? AND sender_user_id != ? "
        "AND kind NOT IN (${_changeKinds.map((k) => "'$k'").join(', ')}) "
        // Messages their sender deleted aren't unread either.
        "AND NOT EXISTS (SELECT 1 FROM local_messages d WHERE d.chat_id = m.chat_id AND d.kind = 'delete' "
        'AND d.target_id = m.id AND d.sender_user_id = m.sender_user_id) '
        'AND seq > MAX(?, COALESCE((SELECT joined_seq FROM local_members WHERE chat_id = ? AND user_id = ?), 0))',
        variables: [
          Variable.withString(c.id),
          Variable.withString(me),
          Variable.withInt(c.myLastReadSeq),
          Variable.withString(c.id),
          Variable.withString(me),
        ],
        readsFrom: {localMessages},
      ).getSingle();
      items.add(ChatListItem(
        chat: c,
        members: members.where((m) => m.chatId == c.id).toList(),
        last: last,
        lastChanges: last == null ? const [] : await changesTo(c.id, last.id),
        unread: unread.read<int>('n'),
      ));
    }
    items.sort(compareChatListItems);
    return items;
  }

  // --- keys ---

  Future<void> putKey(String chatId, int epoch, List<int> key) =>
      into(localKeys).insertOnConflictUpdate(KeyRow(chatId: chatId, epoch: epoch, key: Uint8List.fromList(key)));

  Future<Uint8List?> key(String chatId, int epoch) async =>
      (await (select(localKeys)..where((k) => k.chatId.equals(chatId) & k.epoch.equals(epoch))).getSingleOrNull())?.key;

  /// Every chat key held (pairing hands them all to a new device).
  Future<List<KeyRow>> allKeys() => select(localKeys).get();

  Future<List<KeyRow>> keysOf(String chatId) => (select(localKeys)..where((k) => k.chatId.equals(chatId))).get();

  // --- directory ---

  Future<UserRow?> userById(String id) => (select(localUsers)..where((u) => u.id.equals(id))).getSingleOrNull();

  Future<List<UserRow>> allUsers() => select(localUsers).get();

  Stream<List<UserRow>> watchUsers() => (select(localUsers)..orderBy([(u) => OrderingTerm(expression: u.name)])).watch();

  /// Writes every column of [u], nulls included (a removed profile photo clears its key).
  Future<void> putUser(UserRow u) => into(localUsers).insertOnConflictUpdate(u.toCompanion(false));

  Future<DeviceRow?> deviceById(String id) => (select(localDevices)..where((d) => d.id.equals(id))).getSingleOrNull();

  Future<List<DeviceRow>> devicesOf(Iterable<String> userIds) =>
      (select(localDevices)..where((d) => d.userId.isIn(userIds))).get();

  Future<List<DeviceRow>> allDevices() => select(localDevices).get();

  Future<void> putDevice(DeviceRow d) => into(localDevices).insertOnConflictUpdate(d);

  // --- admin pins ---

  /// Per family this device has seen, the admins it trusts there.
  Future<Map<int, Set<String>>> familyPins() async {
    final pins = {for (final f in await select(localFamilies).get()) f.id: <String>{}};
    for (final a in await select(localFamilyAdmins).get()) {
      pins[a.familyId]?.add(a.userId);
    }
    return pins;
  }

  /// Replaces the pins of the families in [pins] and marks them seen. Other families keep their
  /// seen mark and their pins, frozen: a family is never seen for the first time twice.
  /// [proofs]: per family, the sig of each pinned admin's valid promotion proof listed now; a pin
  /// with none listed keeps the one last seen. In those families, a dropped pin's last seen proof
  /// is revoked, and so is one a different proof replaces.
  Future<void> updateFamilyPins(Map<int, Set<String>> pins, {Map<int, Map<String, String>> proofs = const {}}) =>
      transaction(() async {
        final before = await (select(localFamilyAdmins)..where((a) => a.familyId.isIn(pins.keys))).get();
        final last = {for (final a in before) (a.familyId, a.userId): a.proofSig};
        final revoked = <RevokedProofRow>[
          for (final a in before)
            if (a.proofSig case final sig?)
              if (!pins[a.familyId]!.contains(a.userId) || (proofs[a.familyId]?[a.userId] ?? sig) != sig)
                RevokedProofRow(familyId: a.familyId, userId: a.userId, sig: sig),
        ];
        await (delete(localFamilyAdmins)..where((a) => a.familyId.isIn(pins.keys))).go();
        await batch((b) {
          b.insertAll(localRevokedProofs, revoked, mode: InsertMode.insertOrIgnore);
          b.insertAllOnConflictUpdate(localFamilies, [for (final id in pins.keys) FamilyRow(id: id)]);
          b.insertAll(localFamilyAdmins, [
            for (final e in pins.entries)
              for (final u in e.value)
                FamilyAdminRow(familyId: e.key, userId: u, proofSig: proofs[e.key]?[u] ?? last[(e.key, u)]),
          ]);
        });
      });

  /// Every revoked promotion proof, as (familyId, userId, sig).
  Future<Set<(int, String, String)>> revokedProofs() async =>
      {for (final r in await select(localRevokedProofs).get()) (r.familyId, r.userId, r.sig)};

  /// Replaces every family's pins with [pins], for the pairing handover only (from a trusted
  /// device): a family absent from it is no longer seen. Revoked proofs stay.
  Future<void> replaceFamilyPins(Map<int, Set<String>> pins) => transaction(() async {
        await delete(localFamilyAdmins).go();
        await delete(localFamilies).go();
        await batch((b) {
          b.insertAll(localFamilies, [for (final id in pins.keys) FamilyRow(id: id)]);
          b.insertAll(localFamilyAdmins, [
            for (final e in pins.entries)
              for (final u in e.value) FamilyAdminRow(familyId: e.key, userId: u),
          ]);
        });
      });

  // --- reset banners ---

  /// Records a witnessed reset once (a later call keeps the dismissals).
  Future<void> recordReset({
    required String id,
    required String userId,
    required String signerUserId,
    required String signerKind,
    required int createdAt,
  }) =>
      into(localResets).insert(
        LocalResetsCompanion.insert(
          id: id,
          userId: userId,
          signerUserId: signerUserId,
          signerKind: signerKind,
          createdAt: createdAt,
        ),
        mode: InsertMode.insertOrIgnore,
      );

  Future<List<ResetRow>> allResets() => select(localResets).get();

  /// Resets of [chatId]'s members other than [myUserId] whose banner wasn't dismissed there, oldest first.
  Stream<List<ResetRow>> watchResetBanners(String chatId, String myUserId) => customSelect(
        'SELECT * FROM local_resets WHERE user_id != ? AND user_id IN '
        '(SELECT user_id FROM local_members WHERE chat_id = ?) ORDER BY created_at',
        variables: [Variable.withString(myUserId), Variable.withString(chatId)],
        readsFrom: {localResets, localMembers},
      ).watch().map((rows) => [
            for (final q in rows)
              if (!_ids(q.read<String>('dismissed_chats')).contains(chatId)) localResets.map(q.data),
          ]);

  Future<void> dismissResetBanner(String resetId, String chatId) => transaction(() async {
        final row = await (select(localResets)..where((r) => r.id.equals(resetId))).getSingleOrNull();
        if (row == null) return;
        final ids = {..._ids(row.dismissedChats), chatId};
        await (update(localResets)..where((r) => r.id.equals(resetId)))
            .write(LocalResetsCompanion(dismissedChats: Value(jsonEncode(ids.toList()))));
      });

  static Set<String> _ids(String json) {
    try {
      return {...(jsonDecode(json) as List).cast<String>()};
    } on FormatException {
      return {};
    }
  }
}

/// The app's database file (IndexedDB/OPFS via wasm on the web).
ChatDb openChatDb() => ChatDb(
      driftDatabase(
        name: 'famchat_chats',
        web: DriftWebOptions(
          sqlite3Wasm: Uri.parse('sqlite3.wasm'),
          driftWorker: Uri.parse('drift_worker.js'),
        ),
        // Android's push handler runs in a background isolate; both share one connection.
        native: const DriftNativeOptions(shareAcrossIsolates: true),
      ),
    );
