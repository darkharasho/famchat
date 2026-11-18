import 'package:drift/native.dart';
import 'package:famchat/chat/db/chat_db.dart';
import 'package:famchat/chat/plaintext.dart';
import 'package:famchat/chat/wire.dart';
import 'package:famchat/crypto/encoding.dart';
import 'package:famchat/crypto/envelope.dart';
import 'package:famchat/crypto/keys.dart';
import 'package:famchat/games/rules.dart';
import 'package:famchat/push/preview.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

const chatId = 'C1', messageId = 'M1', userId = 'bob', deviceId = 'bob-d';

void main() {
  late ChatDb db;
  late DeviceKeys sender;
  final chatKey = Uint8List.fromList(List.generate(32, (i) => i));

  Future<void> putSender({bool trusted = true, bool revoked = false, bool certValid = true, String owner = userId}) async =>
      db.putDevice(DeviceRow(
        id: deviceId,
        userId: owner,
        name: 'Phone',
        encPub: 'x',
        signPub: b64url(await sender.signPub()),
        certSig: 'x',
        revoked: revoked,
        certValid: certValid,
        trusted: trusted,
      ));

  Future<Map<String, Object?>> envelopeOf(Plaintext p, {DeviceKeys? signer, int epoch = 1}) async =>
      (await encryptEnvelope(
        chatKey: chatKey,
        epoch: epoch,
        chatId: chatId,
        messageId: messageId,
        senderDeviceId: deviceId,
        signKey: (signer ?? sender).sign,
        plaintext: p.encode(),
      ))
          .toJson();

  Future<String?> preview(Map<String, Object?> env) => previewText(
      db: db, chatId: chatId, messageId: messageId, senderUserId: userId, senderDeviceId: deviceId, envelope: env);

  setUpAll(() async => sender = await DeviceKeys.generate());
  setUp(() async {
    db = ChatDb(NativeDatabase.memory());
    await putSender();
    await db.putKey(chatId, 1, chatKey);
  });
  tearDown(() => db.close());

  test('text message returns its text', () async {
    expect(await preview(await envelopeOf(const TextBody('hello there'))), 'hello there');
  });

  test('text over 300 chars is cut with an ellipsis', () async {
    expect(await preview(await envelopeOf(TextBody('a' * 400))), '${'a' * 300}…');
  });

  test('text of exactly 300 chars is not cut', () async {
    expect(await preview(await envelopeOf(TextBody('a' * 300))), 'a' * 300);
  });

  test('the cut never splits an emoji', () async {
    final text = '${'a' * 299}👨‍👩‍👧‍👦${'b' * 10}';
    expect(await preview(await envelopeOf(TextBody(text))), '${'a' * 299}👨‍👩‍👧‍👦…');
  });

  test('photo returns 📷 Photo', () async {
    final photo = PhotoBody(
      mediaKey: '01JMEDAA000000000000000000',
      thumbKey: '01JTHMB0000000000000000000',
      key: Uint8List.fromList(List.filled(32, 1)),
      sha256: Uint8List.fromList(List.filled(32, 2)),
      thumbSha256: Uint8List.fromList(List.filled(32, 3)),
      width: 2048,
      height: 1536,
      bytes: 512000,
    );
    expect(await preview(await envelopeOf(photo)), '📷 Photo');
  });

  test('voice returns 🎤 Voice message', () async {
    final voice = VoiceBody(
      mediaKey: '01JMEDAA000000000000000000',
      key: Uint8List.fromList(List.filled(32, 1)),
      sha256: Uint8List.fromList(List.filled(32, 2)),
      durationMs: 4200,
      waveform: [for (var i = 0; i < 64; i++) i * 4],
      bytes: 25000,
    );
    expect(await preview(await envelopeOf(voice)), '🎤 Voice message');
  });

  test('video returns 🎥 Video', () async {
    final video = VideoBody(
      mediaKey: '01JMEDAA000000000000000000',
      key: Uint8List.fromList(List.filled(32, 1)),
      sha256: Uint8List.fromList(List.filled(32, 2)),
      width: 1280,
      height: 720,
      durationMs: 12500,
      bytes: 4000000,
    );
    expect(await preview(await envelopeOf(video)), '🎥 Video');
  });

  test('gif returns GIF', () async {
    const gif = GifBody(slug: 'cat', title: 'Cat', url: 'https://static.klipy.com/cat.webp', width: 200, height: 100);
    expect(await preview(await envelopeOf(gif)), 'GIF');
  });

  test('unknown kind returns null', () async {
    expect(await preview(await envelopeOf(const UnknownBody('reaction'))), isNull);
  });

  test('untrusted sender device returns null', () async {
    await putSender(trusted: false);
    expect(await preview(await envelopeOf(const TextBody('hi'))), isNull);
  });

  test('revoked sender device returns null', () async {
    await putSender(revoked: true);
    expect(await preview(await envelopeOf(const TextBody('hi'))), isNull);
  });

  test('sender device whose cert is not valid returns null', () async {
    await putSender(certValid: false);
    expect(await preview(await envelopeOf(const TextBody('hi'))), isNull);
  });

  test('sender device of another user returns null', () async {
    await putSender(owner: 'eve');
    expect(await preview(await envelopeOf(const TextBody('hi'))), isNull);
  });

  test('unknown sender device returns null', () async {
    final env = await envelopeOf(const TextBody('hi'));
    expect(
        await previewText(
            db: db, chatId: chatId, messageId: messageId, senderUserId: userId, senderDeviceId: 'nope', envelope: env),
        isNull);
  });

  test('missing chat key returns null', () async {
    expect(await preview(await envelopeOf(const TextBody('hi'), epoch: 2)), isNull);
  });

  test('bad signature returns null', () async {
    final other = await DeviceKeys.generate();
    expect(await preview(await envelopeOf(const TextBody('hi'), signer: other)), isNull);
  });

  test('malformed envelope returns null', () async {
    expect(await preview({'v': 1}), isNull);
  });

  group('previewBody', () {
    Future<void> chat(String kind) => db.upsertChat(ChatDto(
          id: chatId,
          kind: kind,
          title: 'Fam',
          createdBy: 'me',
          currentEpoch: 1,
          epochReady: true,
          lastSeq: 0,
          lastMessageAt: null,
          createdAt: 1,
          members: const [],
        ));
    Future<String> body() => previewBody(db: db, chatId: chatId, senderUserId: userId, preview: 'hi');

    test('in a group prefixes the sender name', () async {
      await chat('group');
      await db.putUser(UserRow(
          id: userId, name: 'Bob', isAdmin: false, identityPub: 'x', trustedIdentityPub: 'x', knownIdentityPubs: '[]', pinnedAdmin: false, familyIds: '[]'));
      expect(await body(), 'Bob: hi');
    });

    test('in a group falls back to Someone', () async {
      await chat('group');
      expect(await body(), 'Someone: hi');
    });

    test('in a direct chat is the bare preview', () async {
      await chat('direct');
      expect(await body(), 'hi');
    });

    test('in a chat that is neither group nor direct is the bare preview', () async {
      await chat('self');
      expect(await body(), 'hi');
    });

    test('in an unknown chat is the bare preview', () async {
      expect(await body(), 'hi');
    });
  });

  test('mediaLabel', () {
    expect(mediaLabel('photo'), '📷 Photo');
    expect(mediaLabel('voice'), '🎤 Voice message');
    expect(mediaLabel('video'), '🎥 Video');
    expect(mediaLabel('gif'), 'GIF');
    expect(mediaLabel('text'), isNull);
  });

  test('a game message returns its push label', () async {
    expect(await preview(await envelopeOf(const GameBody(GameType.checkers, userId))), '🎲 Started a game of Checkers');
  });

  test('a move with no stored game returns Moved in', () async {
    expect(
      await preview(await envelopeOf(const MoveBody('nope', GameType.chess, 0, {'type': 'play', 'uci': 'e2e4'}))),
      '♟ Moved in Chess',
    );
  });
}
