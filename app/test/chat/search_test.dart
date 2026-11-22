import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:famchat/chat/db/chat_db.dart';
import 'package:famchat/chat/search.dart';
import 'package:flutter_test/flutter_test.dart';

MessageRow text(String id, String chatId, int seq, String body, {String sender = 'bob'}) => MessageRow(
      id: id,
      chatId: chatId,
      seq: seq,
      senderUserId: sender,
      senderDeviceId: '$sender-d',
      kind: 'text',
      body: jsonEncode({'kind': 'text', 'text': body}),
      targetId: null,
      envelope: null,
      createdAt: seq * 1000,
      state: 'sent',
    );

MessageRow change(String id, String chatId, int seq, String kind, String target, {String? newText, String sender = 'bob'}) =>
    text(id, chatId, seq, '', sender: sender).copyWith(
      kind: kind,
      body: Value(jsonEncode({'kind': kind, 'target': target, 'text': ?newText})),
      targetId: Value(target),
    );

void main() {
  late ChatDb db;
  setUp(() => db = ChatDb(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<void> put(List<MessageRow> rows) async {
    for (final r in rows) {
      await db.insertMessageIfAbsent(r);
    }
  }

  test('finds text case-insensitively, newest first, across chats or in one', () async {
    await put([
      text('a1', 'A', 1, 'Pizza on Friday?'),
      text('a2', 'A', 2, 'no thanks'),
      text('b1', 'B', 3, 'pizza place closed', sender: 'carol'),
    ]);
    expect((await searchMessages(db, 'PIZZA')).map((h) => h.message.id), ['b1', 'a1']);
    expect((await searchMessages(db, 'pizza', chatId: 'A')).map((h) => h.message.id), ['a1']);
    expect(await searchMessages(db, 'sushi'), isEmpty);
    expect(await searchMessages(db, '   '), isEmpty);
  });

  test('finds polls by their question or an option, and skips deleted ones', () async {
    MessageRow poll(String id, int seq, String q, List<String> options) => text(id, 'A', seq, '').copyWith(
          kind: 'poll',
          body: Value(jsonEncode({'kind': 'poll', 'question': q, 'options': options, 'multi': false})),
        );
    await put([
      poll('p1', 1, 'Thanksgiving dinner?', ['Thursday', 'Saturday']),
      poll('p2', 2, 'Which movie?', ['Dune', 'Up']),
      change('d1', 'A', 3, 'delete', 'p2'),
    ]);
    final hits = await searchMessages(db, 'saturday');
    expect(hits.map((h) => h.message.id), ['p1']);
    expect(hits.single.text, '📊 Thanksgiving dinner? · Thursday · Saturday');
    expect((await searchMessages(db, 'thanksgiving')).map((h) => h.message.id), ['p1']);
    expect(await searchMessages(db, 'dune'), isEmpty);
  });

  test("matches the latest edit, not the original, and skips deleted messages", () async {
    await put([
      text('m1', 'A', 1, 'meet at 5'),
      change('e1', 'A', 2, 'edit', 'm1', newText: 'meet at 6'),
      text('m2', 'A', 3, 'secret plan'),
      change('d1', 'A', 4, 'delete', 'm2'),
      // Someone else's edit doesn't count.
      change('e2', 'A', 5, 'edit', 'm1', newText: 'meet at 9', sender: 'eve'),
    ]);
    expect((await searchMessages(db, 'at 6')).map((h) => (h.message.id, h.text)), [('m1', 'meet at 6')]);
    expect(await searchMessages(db, 'at 5'), isEmpty);
    expect(await searchMessages(db, 'at 9'), isEmpty);
    expect(await searchMessages(db, 'secret'), isEmpty);
  });

  test('characters LIKE treats specially are matched literally', () async {
    await put([text('m1', 'A', 1, '100% sure'), text('m2', 'A', 2, '100 sure'), text('m3', 'A', 3, 'snake_case')]);
    expect((await searchMessages(db, '100%')).map((h) => h.message.id), ['m1']);
    expect((await searchMessages(db, 'e_c')).map((h) => h.message.id), ['m3']);
  });

  test('snippetAround keeps the match in view', () {
    final long = '${'a' * 100} needle ${'b' * 100}';
    final s = snippetAround(long, 'needle', radius: 10);
    expect(s, startsWith('…'));
    expect(s, endsWith('…'));
    expect(s, contains('needle'));
    expect(snippetAround('short needle', 'needle'), 'short needle');
    expect(snippetAround('line one\nneedle', 'needle'), 'line one needle');
  });

  test('matchRanges finds every case-insensitive match', () {
    expect(matchRanges('Ha ha HA', 'ha'), [(0, 2), (3, 5), (6, 8)]);
    expect(matchRanges('abc', ''), isEmpty);
  });

  test('finds photo and video captions', () async {
    final photo = text('p1', 'A', 1, '').copyWith(
      kind: 'photo',
      body: Value(jsonEncode({'kind': 'photo', 'caption': 'Beach day'})),
    );
    await put([photo, text('t1', 'A', 2, 'no beach')]);
    expect((await searchMessages(db, 'beach day')).map((h) => (h.message.id, h.text)), [('p1', 'Beach day')]);
  });

  group('voice transcripts', () {
    MessageRow clip(String id, int seq, {String sender = 'bob'}) => text(id, 'A', seq, '', sender: sender).copyWith(
          kind: 'voice',
          body: Value(jsonEncode({'kind': 'voice', 'mediaKey': 'k', 'durationMs': 1000})),
        );

    test('finds a voice message by its transcript', () async {
      await put([clip('v1', 1), change('t1', 'A', 2, 'transcript', 'v1', newText: 'Pick up milk')]);
      final hits = await searchMessages(db, 'milk');
      expect(hits.map((h) => h.message.id), ['v1']);
      expect(hits.single.text, '🎤 Pick up milk');
    });

    test("others' transcripts and deleted clips don't match", () async {
      await put([
        clip('v1', 1),
        change('t1', 'A', 2, 'transcript', 'v1', newText: 'pick up milk', sender: 'carol'),
        clip('v2', 3),
        change('t2', 'A', 4, 'transcript', 'v2', newText: 'more milk'),
        change('d2', 'A', 5, 'delete', 'v2'),
      ]);
      expect(await searchMessages(db, 'milk'), isEmpty);
    });

    test('only the latest transcript matches', () async {
      await put([
        clip('v1', 1),
        change('t1', 'A', 2, 'transcript', 'v1', newText: 'milk'),
        change('t2', 'A', 3, 'transcript', 'v1', newText: 'bread'),
      ]);
      expect(await searchMessages(db, 'milk'), isEmpty);
      expect((await searchMessages(db, 'bread')).single.text, '🎤 bread');
    });
  });
}
