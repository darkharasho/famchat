import 'package:drift/native.dart';
import 'package:famchat/chat/db/chat_db.dart';
import 'package:flutter_test/flutter_test.dart';

MessageRow _msg(String id, {String chat = 'C', String kind = 'voice'}) => MessageRow(
    id: id, chatId: chat, seq: 1, senderUserId: 'B', senderDeviceId: 'D', kind: kind, body: '{}', targetId: null,
    envelope: null, createdAt: 1, state: 'sent');

void main() {
  late ChatDb db;
  setUp(() => db = ChatDb(NativeDatabase.memory()));
  tearDown(() => db.close());

  test('a later local transcript replaces the earlier one', () async {
    await db.putLocalTranscript('C', 'M', 'one');
    await db.putLocalTranscript('C', 'M', 'two');
    expect(await db.localTranscriptOf('M'), 'two');
    expect(await db.watchLocalTranscripts('other').first, isEmpty);
  });

  test('purging or deleting a message removes its local transcript', () async {
    for (final id in ['M1', 'M2']) {
      await db.insertMessageIfAbsent(_msg(id));
      await db.putLocalTranscript('C', id, 'text $id');
    }
    await db.purgeMessages(['M1']);
    expect(await db.localTranscriptOf('M1'), isNull);
    await db.deleteMessages(['M2']);
    expect(await db.localTranscriptOf('M2'), isNull);
  });

  test("a chat that goes takes its local transcripts", () async {
    await db.putLocalTranscript('C', 'M', 'text');
    await db.deleteChat('C');
    expect(await db.localTranscriptOf('M'), isNull);
  });
}
