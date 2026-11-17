import 'dart:convert';
import 'dart:typed_data';

import 'package:famchat/api/api_client.dart';
import 'package:famchat/api/models.dart';
import 'package:famchat/api/token_manager.dart';
import 'package:famchat/chat/http_chat_api.dart';
import 'package:famchat/chat/plaintext.dart';
import 'package:famchat/chat/ulid.dart';
import 'package:famchat/chat/wire.dart';
import 'package:famchat/crypto/encoding.dart';
import 'package:famchat/crypto/wrap.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const chatJson = {
  'id': 'C1',
  'kind': 'group',
  'title': 'Family',
  'createdBy': 'U1',
  'currentEpoch': 2,
  'epochReady': false,
  'lastSeq': 7,
  'lastMessageAt': 1700000000000,
  'createdAt': 1600000000000,
  'members': [
    {'userId': 'U1', 'joinedSeq': 0, 'lastReadSeq': 7},
    {'userId': 'U2', 'joinedSeq': 3, 'lastReadSeq': 5},
  ],
};

final wrapJson = {
  'chatId': 'C1',
  'epoch': 1,
  'recipientDeviceId': 'D2',
  'wrapperDeviceId': 'D1',
  'sealed': b64url(List.filled(72, 1)),
  'sig': b64url(List.filled(64, 2)),
};

ApiClient client(Future<http.Response> Function(http.Request r) handler) {
  final api = ApiClient(client: MockClient(handler), base: Uri.parse('https://famchat.dev'));
  api.tokens = TokenManager(
    refreshCall: (_) async => throw StateError('no refresh'),
    readRefreshToken: () async => 'r',
    saveRefreshToken: (_) async {},
    onRevoked: () async {},
  )..setAccessToken('tok');
  return api;
}

http.Response json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

void main() {
  group('dto parsing', () {
    test('chat', () {
      final c = ChatDto.fromJson(chatJson);
      expect([c.id, c.kind, c.title, c.createdBy, c.currentEpoch, c.epochReady, c.lastSeq], ['C1', 'group', 'Family', 'U1', 2, false, 7]);
      expect(c.lastMessageAt, 1700000000000);
      expect(c.members.map((m) => (m.userId, m.joinedSeq, m.lastReadSeq)), [('U1', 0, 7), ('U2', 3, 5)]);
      final d = ChatDto.fromJson({...chatJson, 'title': null, 'lastMessageAt': null, 'kind': 'direct'});
      expect(d.title, isNull);
      expect(d.lastMessageAt, isNull);
    });

    test('user with devices', () {
      final u = UserDto.fromJson({
        'id': 'U1',
        'name': 'Mom',
        'isAdmin': true,
        'identityPub': 'aa',
        'devices': [
          {'id': 'D1', 'name': 'Phone', 'platform': 'ios', 'encPub': 'e', 'signPub': 's', 'certSig': 'c', 'revoked': false},
        ],
      });
      expect(u.devices.single.userId, 'U1');
      expect(u.devices.single.revoked, isFalse);
      expect(u.isAdmin, isTrue);
      expect(u.deleted, isFalse);
      final gone = UserDto.fromJson({'id': 'U2', 'name': 'Deleted user', 'isAdmin': false, 'identityPub': 'bb', 'devices': [], 'deleted': true});
      expect(gone.deleted, isTrue);
    });

    test('former is read and defaults to false', () {
      final base = {'id': 'U2', 'name': 'Cy', 'isAdmin': false, 'identityPub': 'bb', 'devices': []};
      expect(UserDto.fromJson(base).former, isFalse);
      expect(UserDto.fromJson({...base, 'former': true}).former, isTrue);
    });

    test('message keeps the envelope map', () {
      final m = MessageDto.fromJson({
        'chatId': 'C1', 'seq': 3, 'id': 'M1', 'senderUserId': 'U1', 'senderDeviceId': 'D1',
        'envelope': {'v': 1, 'epoch': 1, 'nonce': 'a', 'ct': 'b', 'sig': 'c'}, 'createdAt': 5,
      });
      expect(m.envelope['epoch'], 1);
      expect(m.seq, 3);
    });

    test('mistyped fields throw FormatException', () {
      expect(() => ChatDto.fromJson({...chatJson, 'lastSeq': '7'}), throwsFormatException);
      expect(() => ChatDto.fromJson({...chatJson, 'members': null}), throwsFormatException);
      expect(() => MessageDto.fromJson({'chatId': 'C1'}), throwsFormatException);
    });
  });

  group('HttpChatApi', () {
    test('calls the contract paths and parses', () async {
      final seen = <String>[];
      final api = HttpChatApi(client((r) async {
        seen.add('${r.method} ${r.url.path}${r.url.hasQuery ? '?${r.url.query}' : ''} ${r.headers['authorization']}');
        return switch ('${r.method} ${r.url.path}') {
          'GET /api/chats' => json({'chats': [chatJson]}),
          'GET /api/chats/C1/messages' => json({'messages': []}),
          'POST /api/chats' => json({'chat': chatJson, 'created': true}, 201),
          'GET /api/keys/wraps' => json({'wraps': [wrapJson]}),
          'PUT /api/keys/wraps' => json({'added': 1}),
          'GET /api/keys/missing' => json({'missing': [{'chatId': 'C1', 'epoch': 1, 'deviceId': 'D3'}]}),
          'POST /api/ws/ticket' => json({'ticket': 'T', 'expiresAt': 1}),
          'DELETE /api/chats/C1/members/U2' => http.Response('', 204),
          _ => json({'error': 'not_found'}, 404),
        };
      }));
      expect((await api.chats()).single.id, 'C1');
      await api.messages('C1', after: 4, limit: 50);
      final created = await api.createChat(id: 'C1', kind: 'group', title: 'Family', userIds: ['U2'], wraps: [ChatKeyWrap.fromJson(wrapJson)]);
      expect(created.created, isTrue);
      expect((await api.wraps(chatId: 'C1')).single.recipientDeviceId, 'D2');
      expect(await api.putWraps([ChatKeyWrap.fromJson(wrapJson)]), 1);
      expect((await api.missingWraps()).single.deviceId, 'D3');
      expect(await api.wsTicket(), 'T');
      await api.removeMember('C1', 'U2');
      expect(seen, contains('GET /api/chats/C1/messages?after=4&limit=50 Bearer tok'));
      expect(seen, contains('GET /api/keys/wraps?chatId=C1 Bearer tok'));
    });

    test('wraps_mismatch surfaces as ApiException', () async {
      final api = HttpChatApi(client((r) async => json({'error': 'wraps_mismatch'}, 409)));
      expect(
        () => api.createEpoch('C1', 2, const []),
        throwsA(isA<ApiException>().having((e) => e.code, 'code', 'wraps_mismatch').having((e) => e.status, 'status', 409)),
      );
    });
  });

  test('ulid sorts by time and is 26 Crockford chars', () {
    final a = newUlid(DateTime.fromMillisecondsSinceEpoch(1000));
    final b = newUlid(DateTime.fromMillisecondsSinceEpoch(2000));
    expect(a, hasLength(26));
    expect(RegExp(r'^[0-9A-HJKMNP-TV-Z]{26}$').hasMatch(a), isTrue);
    expect(a.compareTo(b), lessThan(0));
    expect(newUlid(), isNot(newUlid()));
  });

  test('ulids made in the same millisecond sort in creation order', () {
    final t = DateTime.fromMillisecondsSinceEpoch(5000);
    final ids = [for (var i = 0; i < 200; i++) newUlid(t)];
    expect([...ids]..sort(), ids);
    expect(ids.toSet(), hasLength(200));
    // A clock that steps back doesn't break the order either.
    final back = newUlid(DateTime.fromMillisecondsSinceEpoch(4000));
    expect(back.compareTo(ids.last), greaterThan(0));
  });

  group('plaintext', () {
    test('text and reaction round-trip', () {
      expect(Plaintext.decode(const TextBody('hi').encode()), isA<TextBody>().having((t) => t.text, 'text', 'hi'));
      final r = Plaintext.decode(const ReactionBody('M1', '👍').encode()) as ReactionBody;
      expect((r.target, r.emoji), ('M1', '👍'));
    });

    test('unknown kinds keep their whole body for a later version', () {
      final p = Plaintext.decode(utf8.encode('{"kind":"sticker","key":"abc","w":2048}'));
      expect(p.toJson(), {'kind': 'sticker', 'key': 'abc', 'w': 2048});
    });

    PhotoBody photo() => PhotoBody(
          mediaKey: '01JMEDAA000000000000000000',
          thumbKey: '01JTHMB0000000000000000000',
          key: Uint8List.fromList(List.filled(32, 1)),
          sha256: Uint8List.fromList(List.filled(32, 2)),
          thumbSha256: Uint8List.fromList(List.filled(32, 3)),
          width: 2048,
          height: 1536,
          bytes: 512000,
          mime: 'image/jpeg',
        );

    test('photo round-trips', () {
      expect(photo().toJson(), {
        'kind': 'photo',
        'mediaKey': '01JMEDAA000000000000000000',
        'thumbKey': '01JTHMB0000000000000000000',
        'key': b64url(List.filled(32, 1)),
        'sha256': b64url(List.filled(32, 2)),
        'thumbSha256': b64url(List.filled(32, 3)),
        'width': 2048,
        'height': 1536,
        'bytes': 512000,
        'mime': 'image/jpeg',
      });
      final p = Plaintext.decode(photo().encode()) as PhotoBody;
      expect(p.toJson(), photo().toJson());
      expect(p.key, List.filled(32, 1));
    });

    test('photo with a short key or bad field is rejected', () {
      for (final bad in <Map<String, Object?>>[
        {'key': b64url(List.filled(31, 1))},
        {'sha256': 'not base64!'},
        {'thumbSha256': b64url(List.filled(33, 1))},
        {'width': 0},
        {'height': '10'},
        {'bytes': -1},
        {'mediaKey': ''},
        {'mediaKey': '..'},
        {'thumbKey': '01jthmb0000000000000000000'},
        {'thumbKey': null},
        {'mime': 7},
      ]) {
        final j = {...photo().toJson(), ...bad};
        expect(() => Plaintext.decode(utf8.encode(jsonEncode(j))), throwsFormatException, reason: '$bad');
      }
    });

    test('unknown kinds are kept, broken bodies throw', () {
      expect(Plaintext.decode(utf8.encode('{"kind":"sticker","x":1}')), isA<UnknownBody>().having((u) => u.kind, 'kind', 'sticker'));
      expect(() => Plaintext.decode(utf8.encode('nope')), throwsFormatException);
      expect(() => Plaintext.decode(utf8.encode('{"kind":"text"}')), throwsFormatException);
      expect(() => Plaintext.decode(utf8.encode('{"text":"x"}')), throwsFormatException);
    });

    test('text validation trims and caps at 4000', () {
      expect(validMessageText('  hi \n'), 'hi');
      expect(validMessageText('   '), isNull);
      expect(validMessageText('x' * 4001), isNull);
      expect(validMessageText('x' * 4000), hasLength(4000));
    });
  });
}
