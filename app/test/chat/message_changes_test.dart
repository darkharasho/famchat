import 'dart:convert';
import 'dart:typed_data';

import 'package:famchat/chat/db/chat_db.dart';
import 'package:famchat/chat/message_changes.dart';
import 'package:famchat/chat/plaintext.dart';
import 'package:famchat/screens/chats/chat_list.dart' show messageSnippet;
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
      EditBody(:final target) || DeleteBody(:final target) || ReactionBody(:final target) || PinBody(:final target) =>
        target,
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

    test('a stale preview edit (old text) after a real edit is ignored: the edit stands', () {
      final rows = [
        row('a', const TextBody(link), id: 't'),
        row('a', const EditBody('t', '$link wow')),
        row('a', late('t', link)), // higher seq, carrying the text from before the edit
      ];
      expect(rows[2].seq! > rows[1].seq!, isTrue);
      final c = messageChanges(rows);
      expect(c.textOf(rows.first), '$link wow');
      expect(c.previewOf(rows.first), isNull);
      expect(c.edited, {'t'});
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

  PhotoBody photo({String? caption, String? replyTo, List<String> mentions = const []}) => PhotoBody(
        mediaKey: '01JMEDAA000000000000000000',
        thumbKey: '01JTHMB0000000000000000000',
        key: Uint8List.fromList(List.filled(32, 1)),
        sha256: Uint8List.fromList(List.filled(32, 2)),
        thumbSha256: Uint8List.fromList(List.filled(32, 3)),
        width: 20,
        height: 10,
        bytes: 500,
        caption: caption,
        replyTo: replyTo,
        mentions: mentions,
      );

  test('a photo or video carries a caption, reply and mentions', () {
    final p = Plaintext.decode(photo(caption: 'beach day', replyTo: 'r', mentions: ['u']).encode()) as PhotoBody;
    expect((p.caption, p.replyTo), ('beach day', 'r'));
    expect(p.mentions, ['u']);
    final v = Plaintext.decode(VideoBody(
      mediaKey: '01JMEDAA000000000000000000',
      key: Uint8List.fromList(List.filled(32, 1)),
      sha256: Uint8List.fromList(List.filled(32, 2)),
      width: 20,
      height: 10,
      durationMs: 1000,
      bytes: 500,
      caption: 'clip',
    ).encode()) as VideoBody;
    expect(v.caption, 'clip');
    expect(photo().toJson().keys, isNot(contains('caption')));
  });

  test('a bad caption, reply or mention list is dropped and the photo still shows', () {
    for (final bad in [
      {'caption': 5},
      {'caption': ''},
      {'caption': '   '},
      {'caption': 'x' * (maxTextLength + 1)},
      {'replyTo': 7},
      {'mentions': 'u'},
      {'mentions': [1]},
    ]) {
      final p = Plaintext.decode(utf8.encode(jsonEncode({...photo().toJson(), ...bad})));
      expect(p, isA<PhotoBody>(), reason: '$bad');
      p as PhotoBody;
      expect((p.caption, p.replyTo), (null, null), reason: '$bad');
      expect(p.mentions, isEmpty, reason: '$bad');
    }
  });

  test("a caption is the message's text: edits by its sender replace it", () {
    final rows = [
      row('a', photo(caption: 'beach', replyTo: 'r', mentions: ['u']), id: 'p'),
      row('a', const EditBody('p', 'beach day')),
      row('b', const EditBody('p', 'hacked')),
      row('a', photo(), id: 'q'),
    ];
    final c = messageChanges(rows);
    expect(c.textOf(rows[0]), 'beach day');
    expect(c.edited, {'p'});
    expect(c.textOf(rows[3]), isNull);
    expect(replyTargetOf(rows[0]), 'r');
    expect(mentionsOf(rows[0]), ['u']);
    expect(messageSnippet(rows[0], c), '📷 beach day');
    expect(messageSnippet(rows[3], c), '📷 Photo');
  });

  test('pins: anyone pins, the latest event per message wins, the newest 3 stay', () {
    final msgs = [for (var i = 0; i < 5; i++) row('a', TextBody('m$i'), id: 'm$i')];
    final rows = [
      ...msgs,
      row('b', const PinBody('m0', pinned: true)),
      row('a', const PinBody('m1', pinned: true)),
      row('b', const PinBody('m1', pinned: false)),
      row('a', const PinBody('m2', pinned: true)),
      row('b', const PinBody('m3', pinned: true)),
      row('a', const PinBody('m4', pinned: true), state: 'failed'),
    ];
    var c = messageChanges(rows);
    expect(c.pinned, ['m3', 'm2', 'm0']);
    expect(c.pinEvents.length, 5, reason: 'the failed one does not count');
    // A fourth pin pushes out the oldest; re-pinning moves one to the front.
    c = messageChanges([...rows, row('a', const PinBody('m1', pinned: true)), row('b', const PinBody('m0', pinned: true))]);
    expect(c.pinned, ['m0', 'm1', 'm3']);
  });

  test('a deleted message is no longer pinned, and pins of unknown messages are ignored', () {
    final rows = [
      row('a', const TextBody('hi'), id: 't'),
      row('b', const PinBody('t', pinned: true)),
      row('b', const PinBody('gone', pinned: true)),
    ];
    expect(messageChanges(rows).pinned, ['t']);
    expect(messageChanges([...rows, row('a', const DeleteBody('t'))]).pinned, isEmpty);
    expect(() => Plaintext.decode(utf8.encode('{"kind":"pin","target":"t"}')), throwsFormatException);
  });

  test('photos sent together carry an album id; a bad one is dropped', () {
    const album = '01JC0000000000000000000001';
    final p = Plaintext.decode(PhotoBody(
      mediaKey: '01JMEDAA000000000000000000',
      thumbKey: '01JTHMB0000000000000000000',
      key: Uint8List.fromList(List.filled(32, 1)),
      sha256: Uint8List.fromList(List.filled(32, 2)),
      thumbSha256: Uint8List.fromList(List.filled(32, 3)),
      width: 20,
      height: 10,
      bytes: 500,
      album: album,
    ).encode()) as PhotoBody;
    expect(p.album, album);
    final bad = Plaintext.decode(utf8.encode(jsonEncode({...p.toJson(), 'album': 'x'}))) as PhotoBody;
    expect(bad.album, isNull);
  });
}
