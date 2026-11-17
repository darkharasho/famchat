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
}
