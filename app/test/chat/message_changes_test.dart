import 'dart:convert';

import 'package:famchat/chat/db/chat_db.dart';
import 'package:famchat/chat/message_changes.dart';
import 'package:famchat/chat/plaintext.dart';
import 'package:flutter_test/flutter_test.dart';

var _n = 0;

MessageRow row(String sender, Plaintext p, {String? id, String state = 'sent'}) {
  _n++;
  return MessageRow(
    id: id ?? 'm$_n',
    chatId: 'c',
    seq: _n,
    senderUserId: sender,
    senderDeviceId: '$sender-d',
    kind: p.kind,
    body: jsonEncode(p.toJson()),
    targetId: switch (p) {
      EditBody(:final target) || DeleteBody(:final target) || ReactionBody(:final target) => target,
      _ => null,
    },
    envelope: null,
    createdAt: _n,
    state: state,
  );
}

void main() {
  test('plaintext round trip of replies, edits and deletes', () {
    for (final p in [
      const TextBody('hi', replyTo: 'x'),
      const EditBody('x', 'new'),
      const DeleteBody('x'),
    ]) {
      expect(Plaintext.decode(p.encode()).toJson(), p.toJson());
    }
    expect(Plaintext.decode(const TextBody('hi').encode()).toJson().containsKey('replyTo'), isFalse);
    expect(() => Plaintext.decode(utf8.encode('{"kind":"edit","target":"x","text":""}')), throwsFormatException);
    expect(() => Plaintext.decode(utf8.encode('{"kind":"delete"}')), throwsFormatException);
    expect(() => Plaintext.decode(utf8.encode('{"kind":"text","text":"a","replyTo":5}')), throwsFormatException);
  });

  test("the latest edit by the message's sender wins", () {
    final rows = [
      row('a', const TextBody('hi'), id: 't'),
      row('a', const EditBody('t', 'hello')),
      row('b', const EditBody('t', 'hacked')),
      row('a', const EditBody('t', 'hello!')),
      row('a', const EditBody('t', 'not sent'), state: 'failed'),
    ];
    final c = messageChanges(rows);
    expect(c.edited, {'t'});
    expect(c.textOf(rows.first), 'hello!');
    expect(c.isDeleted('t'), isFalse);
  });

  test("a delete by the sender hides the message and later edits; others' deletes are ignored", () {
    final rows = [
      row('a', const TextBody('one'), id: 'one'),
      row('a', const TextBody('two'), id: 'two'),
      row('b', const DeleteBody('one')),
      row('a', const DeleteBody('two')),
      row('a', const EditBody('two', 'back')),
    ];
    final c = messageChanges(rows);
    expect(c.isDeleted('one'), isFalse);
    expect(c.isDeleted('two'), isTrue);
    expect(c.textOf(rows[1]), isNull);
    expect(c.textOf(rows[0]), 'one');
  });

  test('edits only apply to text; deletes apply to any message', () {
    final photo = MessageRow(
      id: 'p',
      chatId: 'c',
      seq: 100,
      senderUserId: 'a',
      senderDeviceId: 'a-d',
      kind: 'photo',
      body: '{}',
      targetId: null,
      envelope: null,
      createdAt: 0,
      state: 'sent',
    );
    final rows = [photo, row('a', const EditBody('p', 'x')), row('a', const DeleteBody('p'))];
    final c = messageChanges(rows);
    expect(c.edited, isEmpty);
    expect(c.isDeleted('p'), isTrue);
  });

  test('a change stored before its target (out-of-order sends) still applies', () {
    final edit = row('a', const EditBody('t', 'fixed'));
    final del = row('a', const DeleteBody('u'));
    final t = row('a', const TextBody('typo'), id: 't');
    final u = row('a', const TextBody('oops'), id: 'u');
    final c = messageChanges([edit, del, t, u]);
    expect(c.textOf(t), 'fixed');
    expect(c.isDeleted('u'), isTrue);
  });

  test('replyTo of a text', () {
    final r = row('b', const TextBody('yes', replyTo: 't'));
    expect(replyTargetOf(r), 't');
    expect(replyTargetOf(row('b', const TextBody('no'))), isNull);
  });

  test('isChangeKind', () {
    expect(changeKinds, containsAll(['reaction', 'edit', 'delete']));
    expect(changeKinds.contains('text'), isFalse);
  });

  group('late link previews (preview-only edits)', () {
    const link = 'look https://youtu.be/cat';
    const card = LinkPreview(url: 'https://youtu.be/cat', title: 'Cat jumps');
    EditBody late(String target, String text, [LinkPreview? p = card]) =>
        EditBody(target, text, preview: p, previewOnly: true);

    test('round trip; older edits read as plain edits', () {
      final p = late('t', link);
      expect(Plaintext.decode(p.encode()).toJson(), p.toJson());
      expect(const EditBody('t', 'x').toJson().keys, ['kind', 'target', 'text']);
      final bad = Plaintext.decode(utf8.encode(jsonEncode({...p.toJson(), 'preview': 'nope'}))) as EditBody;
      expect((bad.previewOnly, bad.preview), (true, null));
    });

    test("attaches the sender's preview without marking the text edited", () {
      final rows = [row('a', const TextBody(link), id: 't'), row('a', late('t', link))];
      final c = messageChanges(rows);
      expect(c.previewOf(rows.first)?.title, 'Cat jumps');
      expect(c.edited, isEmpty);
      expect(c.textOf(rows.first), link);
    });

    test("someone else's preview is ignored", () {
      final rows = [row('a', const TextBody(link), id: 't'), row('b', late('t', link))];
      final c = messageChanges(rows);
      expect(c.previewOf(rows.first), isNull);
      expect(c.edited, isEmpty);
    });

    test('a preview for other text, without its link, or that failed to check out changes nothing', () {
      final rows = [
        row('a', const TextBody(link), id: 't'),
        row('a', late('t', '$link !')),
        row('a', late('t', link, const LinkPreview(url: 'https://other.io', title: 'Other'))),
        row('a', late('t', link, null)),
      ];
      final c = messageChanges(rows);
      expect(c.previewOf(rows.first), isNull);
      expect(c.edited, isEmpty);
      expect(c.textOf(rows.first), link);
    });

    test('it follows edits: matches the latest text, and goes when an edit drops the link', () {
      final edited = [
        row('a', const TextBody(link), id: 't'),
        row('a', const EditBody('t', '$link wow')),
        row('a', late('t', link)), // made for the old text
        row('a', late('t', '$link wow')),
      ];
      var c = messageChanges(edited);
      expect(c.previewOf(edited.first)?.title, 'Cat jumps');
      expect(c.edited, {'t'}, reason: 'edited by the real edit only');

      final dropped = [...edited, row('a', const EditBody('t', 'never mind'))];
      c = messageChanges(dropped);
      expect(c.previewOf(dropped.first), isNull);

      final deleted = [
        row('a', const TextBody(link), id: 'd'),
        row('a', late('d', link)),
        row('a', const DeleteBody('d')),
      ];
      expect(messageChanges(deleted).previewOf(deleted.first), isNull);
    });
  });
}
