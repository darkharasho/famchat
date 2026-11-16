// The device's local chat store (drift): the UI reads only from here. Plaintext of decrypted messages
// and chat keys live here; the database belongs to one signed-in device (see [ChatDb.bindDevice]).
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

  /// Every message with seq ≤ this is stored locally (the `after=` cursor).
  IntColumn get syncedSeq => integer().withDefault(const Constant(0))();

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

  /// text | reaction | unknown | undecryptable
  TextColumn get kind => text()();

  /// The plaintext JSON (null while undecryptable).
  TextColumn get body => text().nullable()();

  /// For reactions: the message reacted to.
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

@DataClassName('MetaRow')
class Meta extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}

class ChatListItem {
  const ChatListItem({required this.chat, required this.members, required this.last, required this.unread});
  final ChatRow chat;
  final List<MemberRow> members;

  /// The newest message that isn't a reaction.
  final MessageRow? last;
  final int unread;

  int get activity => [chat.createdAt, chat.lastMessageAt ?? 0, last?.createdAt ?? 0].reduce((a, b) => a > b ? a : b);
}

@DriftDatabase(tables: [LocalChats, LocalMembers, LocalMessages, LocalKeys, LocalUsers, LocalDevices, Meta])
class ChatDb extends _$ChatDb {
  ChatDb(super.e);

  @override
  int get schemaVersion => 1;

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
          ),
          onConflict: DoUpdate((_) => LocalChatsCompanion(
                kind: Value(c.kind),
                title: Value(c.title),
                createdBy: Value(c.createdBy),
                currentEpoch: Value(c.currentEpoch),
                epochReady: Value(c.epochReady),
                lastSeq: Value(c.lastSeq),
                lastMessageAt: Value(c.lastMessageAt),
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

  /// Chats with members, last message and unread count (others' non-reaction messages above my read
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
            ..where((m) => m.chatId.equals(c.id) & m.kind.equals('reaction').not())
            ..orderBy([
              (m) => OrderingTerm(expression: m.seq.isNull(), mode: OrderingMode.desc),
              (m) => OrderingTerm(expression: m.seq, mode: OrderingMode.desc),
              (m) => OrderingTerm(expression: m.createdAt, mode: OrderingMode.desc),
            ])
            ..limit(1))
          .getSingleOrNull();
      final unread = await customSelect(
        // Counted from where I joined: history from before is shown, not unread.
        "SELECT COUNT(*) AS n FROM local_messages WHERE chat_id = ? AND sender_user_id != ? AND kind != 'reaction' "
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
        unread: unread.read<int>('n'),
      ));
    }
    items.sort((a, b) => b.activity.compareTo(a.activity));
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

  Future<void> putUser(UserRow u) => into(localUsers).insertOnConflictUpdate(u);

  Future<DeviceRow?> deviceById(String id) => (select(localDevices)..where((d) => d.id.equals(id))).getSingleOrNull();

  Future<List<DeviceRow>> devicesOf(Iterable<String> userIds) =>
      (select(localDevices)..where((d) => d.userId.isIn(userIds))).get();

  Future<void> putDevice(DeviceRow d) => into(localDevices).insertOnConflictUpdate(d);
}

/// The app's database file (IndexedDB/OPFS via wasm on the web).
ChatDb openChatDb() => ChatDb(
      driftDatabase(
        name: 'famchat_chats',
        web: DriftWebOptions(
          sqlite3Wasm: Uri.parse('sqlite3.wasm'),
          driftWorker: Uri.parse('drift_worker.js'),
        ),
      ),
    );
