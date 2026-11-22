import 'package:drift/native.dart';
import 'package:famchat/chat/db/chat_db.dart';
import 'package:flutter_test/flutter_test.dart';

MessageRow _msg(String id,
        {String chat = 'C', String kind = 'voice', String sender = 'B', String? target, int? expiresAt, String state = 'sent'}) =>
    MessageRow(
        id: id, chatId: chat, seq: 1, senderUserId: sender, senderDeviceId: 'D', kind: kind, body: '{}', targetId: target,
        envelope: null, createdAt: 1, state: state, expiresAt: expiresAt);

void main() {
  late ChatDb db;
  setUp(() => db = ChatDb(NativeDatabase.memory()));
  tearDown(() => db.close());

  test('a later local transcript replaces the earlier one', () async {
    await db.insertMessageIfAbsent(_msg('M'));
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
    await db.insertMessageIfAbsent(_msg('M'));
    await db.putLocalTranscript('C', 'M', 'text');
    await db.deleteChat('C');
    expect(await db.localTranscriptOf('M'), isNull);
  });

  test('kept only for a voice message still here', () async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.insertMessageIfAbsent(_msg('T', kind: 'text'));
    await db.insertMessageIfAbsent(_msg('X', expiresAt: now - 1000));
    await db.insertMessageIfAbsent(_msg('L', expiresAt: now + 60000));
    await db.insertMessageIfAbsent(_msg('D'));
    await db.insertMessageIfAbsent(_msg('del', kind: 'delete', target: 'D'));
    await db.insertMessageIfAbsent(_msg('F'));
    // Someone else's delete, and a failed one, don't count.
    await db.insertMessageIfAbsent(_msg('del2', kind: 'delete', target: 'F', sender: 'A'));
    await db.insertMessageIfAbsent(_msg('del3', kind: 'delete', target: 'F', state: 'failed'));
    expect(await db.putLocalTranscript('C', 'gone', 'x'), isFalse);
    expect(await db.putLocalTranscript('C', 'T', 'x'), isFalse);
    expect(await db.putLocalTranscript('other', 'L', 'x'), isFalse);
    expect(await db.putLocalTranscript('C', 'X', 'x'), isFalse);
    expect(await db.putLocalTranscript('C', 'D', 'x'), isFalse);
    expect(await db.putLocalTranscript('C', 'L', 'x'), isTrue);
    expect(await db.putLocalTranscript('C', 'F', 'x'), isTrue);
    expect((await db.watchLocalTranscripts('C').first).keys, unorderedEquals(['L', 'F']));
  });
}
