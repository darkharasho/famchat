import 'package:drift/native.dart';
import 'package:famchat/chat/db/chat_db.dart';
import 'package:famchat/chat/wire.dart';
import 'package:flutter_test/flutter_test.dart';

ChatDto chat(String id, {int createdAt = 1, int? lastMessageAt, int lastSeq = 0, List<String> members = const ['me', 'bob']}) =>
    ChatDto(
      id: id,
      kind: 'group',
      title: id,
      createdBy: 'me',
      currentEpoch: 1,
      epochReady: true,
      lastSeq: lastSeq,
      lastMessageAt: lastMessageAt,
      createdAt: createdAt,
      members: [for (final m in members) MemberDto(userId: m, joinedSeq: 0, lastReadSeq: 0)],
    );

MessageRow msg(String id, String chatId, int? seq, {String sender = 'bob', String kind = 'text', String body = '{"kind":"text","text":"x"}', int createdAt = 10, String state = 'sent'}) =>
    MessageRow(
      id: id,
      chatId: chatId,
      seq: seq,
      senderUserId: sender,
      senderDeviceId: '$sender-d',
      kind: kind,
      body: body,
      targetId: null,
      envelope: null,
      createdAt: createdAt,
      state: state,
    );

void main() {
  late ChatDb db;
  setUp(() => db = ChatDb(NativeDatabase.memory()));
  tearDown(() => db.close());

  test('chat list sorts by activity and counts unread from others only', () async {
    await db.upsertChat(chat('old', createdAt: 1, lastMessageAt: 5));
    await db.upsertChat(chat('new', createdAt: 2, lastMessageAt: 50));
    await db.upsertChat(chat('fresh', createdAt: 20));
    await db.insertMessageIfAbsent(msg('m1', 'old', 1));
    await db.insertMessageIfAbsent(msg('m2', 'old', 2));
    await db.insertMessageIfAbsent(msg('m3', 'old', 3, sender: 'me'));
    await db.insertMessageIfAbsent(msg('m4', 'old', 4, kind: 'reaction', body: '{"kind":"reaction","target":"m1","emoji":"x"}'));
    await db.insertMessageIfAbsent(msg('m5', 'old', 5, kind: 'pin', body: '{"kind":"pin","target":"m1","pinned":true}'));
    await db.setMyLastRead('old', 1);
    final list = await db.watchChatList('me').first;
    expect(list.map((c) => c.chat.id), ['new', 'fresh', 'old']);
    final old = list.last;
    expect(old.unread, 1);
    expect(old.last?.id, 'm3');
    expect(old.members.map((m) => m.userId), containsAll(['me', 'bob']));
  });

  test("votes and poll ends aren't unread and aren't the chat's last message", () async {
    await db.upsertChat(chat('p', createdAt: 1, lastMessageAt: 5));
    await db.insertMessageIfAbsent(msg('m1', 'p', 1, kind: 'poll', body: '{"kind":"poll","question":"Q","options":["a","b"],"multi":false}'));
    await db.insertMessageIfAbsent(msg('m2', 'p', 2, kind: 'vote', body: '{"kind":"vote","target":"m1","choices":[0]}'));
    await db.insertMessageIfAbsent(msg('m3', 'p', 3, kind: 'poll_end', body: '{"kind":"poll_end","target":"m1"}'));
    await db.setMyLastRead('p', 1);
    final item = (await db.watchChatList('me').first).single;
    expect(item.unread, 0);
    expect(item.last?.id, 'm1');
  });

  test('unread starts at the join point for new members', () async {
    await db.upsertChat(ChatDto(
      id: 'g',
      kind: 'group',
      title: 'G',
      createdBy: 'bob',
      currentEpoch: 1,
      epochReady: true,
      lastSeq: 4,
      lastMessageAt: 1,
      createdAt: 1,
      members: const [MemberDto(userId: 'me', joinedSeq: 3, lastReadSeq: 0), MemberDto(userId: 'bob', joinedSeq: 0, lastReadSeq: 4)],
    ));
    for (var i = 1; i <= 4; i++) {
      await db.insertMessageIfAbsent(msg('m$i', 'g', i));
    }
    expect((await db.watchChatList('me').first).single.unread, 1);
  });

  test('a pending own message bumps activity', () async {
    await db.upsertChat(chat('a', createdAt: 1));
    await db.upsertChat(chat('b', createdAt: 2));
    await db.insertMessageIfAbsent(msg('p', 'a', null, sender: 'me', state: 'pending', createdAt: 99));
    expect((await db.watchChatList('me').first).first.chat.id, 'a');
  });

  test('upsert keeps local sync state', () async {
    await db.upsertChat(chat('a'));
    await db.setSyncedSeq('a', 4);
    await db.setMyLastRead('a', 3);
    await db.upsertChat(chat('a', lastSeq: 9, members: ['me', 'bob', 'carol']));
    final row = (await db.chatById('a'))!;
    expect((row.syncedSeq, row.myLastReadSeq, row.lastSeq), (4, 3, 9));
    expect((await db.membersOf('a')).map((m) => m.userId), unorderedEquals(['me', 'bob', 'carol']));
    await db.upsertChat(chat('a', members: ['me']));
    expect((await db.membersOf('a')).map((m) => m.userId), ['me']);
  });

  test('a draft is kept across server updates; a blank one is cleared', () async {
    await db.upsertChat(chat('a'));
    await db.setDraft('a', 'see you at');
    await db.upsertChat(chat('a', lastSeq: 2));
    expect((await db.chatById('a'))!.draft, 'see you at');
    expect((await db.draftOf('a')), 'see you at');
    await db.setDraft('a', '  \n ');
    expect((await db.chatById('a'))!.draft, isNull);
    expect(await db.draftOf('missing'), isNull);
  });

  test('insertMessageIfAbsent dedupes by id', () async {
    await db.upsertChat(chat('a'));
    expect(await db.insertMessageIfAbsent(msg('m1', 'a', 1)), isTrue);
    expect(await db.insertMessageIfAbsent(msg('m1', 'a', 1, body: 'other')), isFalse);
    expect((await db.messageById('m1'))!.body, '{"kind":"text","text":"x"}');
  });

  test('ack moves a pending message into seq order', () async {
    await db.upsertChat(chat('a'));
    await db.insertMessageIfAbsent(msg('p', 'a', null, sender: 'me', state: 'pending', createdAt: 1));
    await db.insertMessageIfAbsent(msg('m1', 'a', 1, createdAt: 5));
    expect((await db.watchMessages('a').first).map((m) => m.id), ['m1', 'p']);
    expect((await db.pendingOutbox('me-d')).map((m) => m.id), ['p']);
    await db.ackMessage('p', seq: 2, createdAt: 7);
    await db.insertMessageIfAbsent(msg('m3', 'a', 3));
    expect((await db.watchMessages('a').first).map((m) => m.id), ['m1', 'p', 'm3']);
    expect(await db.pendingOutbox('me-d'), isEmpty);
    expect((await db.messageById('p'))!.state, 'sent');
  });

  test('deleteChat removes its messages, members and keys', () async {
    await db.upsertChat(chat('a'));
    await db.insertMessageIfAbsent(msg('m1', 'a', 1));
    await db.putKey('a', 1, List.filled(32, 7));
    await db.deleteChat('a');
    expect(await db.chatById('a'), isNull);
    expect(await db.messageById('m1'), isNull);
    expect(await db.key('a', 1), isNull);
    expect(await db.membersOf('a'), isEmpty);
  });

  test('keys round-trip', () async {
    await db.putKey('a', 2, List.filled(32, 9));
    expect(await db.key('a', 2), List.filled(32, 9));
    expect(await db.key('a', 1), isNull);
  });

  test('bindDevice to another device wipes data', () async {
    await db.bindDevice('d1');
    await db.upsertChat(chat('a'));
    await db.bindDevice('d1');
    expect(await db.chatById('a'), isNotNull);
    await db.bindDevice('d2');
    expect(await db.chatById('a'), isNull);
  });
}
