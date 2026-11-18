// Generates (UPDATE_PREVIEW_FIXTURE=1) and checks the fixture that the Swift PreviewCore tests run against,
// so the iPhone notification extension and previewText/previewBody agree case by case.
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:famchat/chat/db/chat_db.dart';
import 'package:famchat/chat/plaintext.dart';
import 'package:famchat/crypto/encoding.dart';
import 'package:famchat/crypto/envelope.dart';
import 'package:famchat/push/preview.dart';
import 'package:famchat/push/preview_keyring.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

const fixturePath = 'ios/PreviewCore/Tests/PreviewCoreTests/Fixtures/preview_fixture.json';

final chatKey = Uint8List.fromList(List.generate(32, (i) => i));

PhotoBody photo() => PhotoBody(
      mediaKey: '01JMEDAA000000000000000000',
      thumbKey: '01JTHMB0000000000000000000',
      key: Uint8List.fromList(List.filled(32, 1)),
      sha256: Uint8List.fromList(List.filled(32, 2)),
      thumbSha256: Uint8List.fromList(List.filled(32, 3)),
      width: 2048,
      height: 1536,
      bytes: 512000,
    );

Future<String> buildFixture() async {
  final ed = Ed25519();
  final signer = await ed.newKeyPairFromSeed(List.filled(32, 7));
  final other = await ed.newKeyPairFromSeed(List.filled(32, 8));
  final signPub = b64url((await signer.extractPublicKey()).bytes);

  final db = ChatDb(NativeDatabase.memory());
  try {
    await db.putUser(UserRow(
        id: 'bob', name: 'Bob', isAdmin: false, identityPub: 'x', trustedIdentityPub: 'x', knownIdentityPubs: '[]', pinnedAdmin: false, familyIds: '[]'));
    for (final (id, kind) in [('D1', 'direct'), ('G1', 'group')]) {
      await db.into(db.localChats).insert(LocalChatsCompanion.insert(
            id: id,
            kind: kind,
            createdBy: 'bob',
            currentEpoch: 1,
            epochReady: true,
            lastSeq: 0,
            createdAt: 0,
            title: const Value(null),
          ));
    }
    for (final (id, user, trusted, revoked) in [
      ('bob-d', 'bob', true, false),
      ('bob-u', 'bob', false, false),
      ('bob-r', 'bob', true, true),
      ('carol-d', 'carol', true, false),
      ('eve-d', 'eve', true, false),
    ]) {
      await db.putDevice(DeviceRow(
        id: id,
        userId: user,
        name: 'Phone',
        encPub: 'x',
        signPub: signPub,
        certSig: 'x',
        revoked: revoked,
        certValid: true,
        trusted: trusted,
      ));
    }
    await db.putKey('D1', 1, chatKey);
    await db.putKey('G1', 1, chatKey);
    final keyring = await buildPreviewKeyring(db);

    final cases = <Map<String, Object?>>[];

    Future<void> add(
      String name,
      List<int> plaintext, {
      String chat = 'D1',
      String user = 'bob',
      String device = 'bob-d',
      int epoch = 1,
      SimpleKeyPair? signWith,
      bool flipCt = false,
      Map<String, Object?> Function(Map<String, Object?>)? mangle,
      String? rawEnv,
      String dataEpoch = '1',
      bool flag = true,
    }) async {
      final i = cases.length;
      const messageId = 'M1';
      final e = await encryptEnvelope(
        chatKey: chatKey,
        epoch: epoch,
        chatId: chat,
        messageId: messageId,
        senderDeviceId: device,
        signKey: signWith ?? signer,
        plaintext: plaintext,
        nonce: List.generate(24, (k) => k + i),
      );
      Map<String, Object?> env = e.toJson();
      if (flipCt) {
        final ct = Uint8List.fromList(e.ct)..[0] ^= 1;
        final aad = envelopeAad(v: 1, chatId: chat, epoch: epoch, messageId: messageId, senderDeviceId: device);
        final sig = await ed.sign([...aad, ...e.nonce, ...ct], keyPair: signer);
        env = {...env, 'ct': b64url(ct), 'sig': b64url(sig.bytes)};
      }
      if (mangle != null) env = mangle(env);
      final userInfo = <String, String>{
        'chatId': chat,
        'messageId': messageId,
        'senderUserId': user,
        'senderDeviceId': device,
        'epoch': dataEpoch,
        'env': rawEnv ?? jsonEncode(env),
        'title': 'FamChat',
        'body': 'New message',
        if (flag) 'preview': '1',
      };
      cases.add({'name': name, 'userInfo': userInfo, 'expected': await expectedBody(db, userInfo)});
    }

    List<int> text(String s) => TextBody(s).encode();

    await add('text-direct', text('hello there'));
    await add('text-group', text('hi all'), chat: 'G1');
    await add('group-unknown-name', text('hey'), chat: 'G1', user: 'carol', device: 'carol-d');
    await add('exactly-300', text('a' * 300));
    await add('cut-emoji', text('${'a' * 299}👨‍👩‍👧🇸🇪é'));
    await add('photo', photo().encode());
    await add(
        'voice',
        VoiceBody(
          mediaKey: '01JMEDAA000000000000000000',
          key: Uint8List.fromList(List.filled(32, 1)),
          sha256: Uint8List.fromList(List.filled(32, 2)),
          durationMs: 4200,
          waveform: [for (var k = 0; k < 64; k++) k * 4],
          bytes: 25000,
        ).encode());
    await add(
        'video',
        VideoBody(
          mediaKey: '01JMEDAA000000000000000000',
          key: Uint8List.fromList(List.filled(32, 1)),
          sha256: Uint8List.fromList(List.filled(32, 2)),
          width: 1280,
          height: 720,
          durationMs: 12500,
          bytes: 4000000,
        ).encode());
    await add('gif', const GifBody(slug: 'cat', title: 'Cat', url: 'https://static.klipy.com/cat.webp', width: 200, height: 100).encode());
    await add('reaction', const ReactionBody('M0', '👍').encode());
    await add('untrusted-device', text('hi'), device: 'bob-u');
    await add('revoked-device', text('hi'), device: 'bob-r');
    await add('wrong-user', text('hi'), device: 'eve-d');
    await add('missing-epoch', text('hi'), epoch: 2);
    await add('bad-signature', text('hi'), signWith: other);
    await add('tampered-ct-resigned', text('hi'), flipCt: true);
    await add('v-bool', text('hi'), mangle: (e) => {...e, 'v': true});
    await add('epoch-float', text('hi'), mangle: (e) => {...e, 'epoch': 1.5});
    await add('padded-b64', text('hi'), mangle: (e) => {...e, 'sig': '${e['sig']}=='});
    await add('env-not-json', text('hi'), rawEnv: 'not json');
    await add('no-preview-flag', text('hi'), flag: false);
    await add('data-epoch-ignored', text('the text'), dataEpoch: '9');

    return '${const JsonEncoder.withIndent('  ').convert({'keyring': keyring, 'cases': cases})}\n';
  } finally {
    await db.close();
  }
}

/// What the Dart app shows for these FCM data keys; null keeps the generic alert.
Future<String?> expectedBody(ChatDb db, Map<String, String> u) async {
  if (u['preview'] != '1') return null;
  try {
    final env = jsonDecode(u['env']!) as Map<String, Object?>;
    final p = await previewText(
      db: db,
      chatId: u['chatId']!,
      messageId: u['messageId']!,
      senderUserId: u['senderUserId']!,
      senderDeviceId: u['senderDeviceId']!,
      envelope: env,
    );
    if (p == null) return null;
    return await previewBody(db: db, chatId: u['chatId']!, senderUserId: u['senderUserId']!, preview: p);
  } catch (_) {
    return null;
  }
}

void main() {
  test('committed fixture matches the Dart implementation', () async {
    final generated = await buildFixture();
    if (Platform.environment['UPDATE_PREVIEW_FIXTURE'] == '1') {
      File(fixturePath).writeAsStringSync(generated);
      return;
    }
    expect(File(fixturePath).readAsStringSync(), generated);
  });

  test('fixture cases have the expected outcomes', () async {
    final j = jsonDecode(await buildFixture()) as Map<String, Object?>;
    final cases = {for (final c in j['cases'] as List) (c as Map)['name']: c['expected']};
    expect(cases.length, greaterThanOrEqualTo(22));
    expect(cases['text-direct'], 'hello there');
    expect(cases['text-group'], 'Bob: hi all');
    expect(cases['group-unknown-name'], 'Someone: hey');
    expect(cases['exactly-300'], 'a' * 300);
    expect(cases['cut-emoji'], '${'a' * 299}👨‍👩‍👧…');
    expect(cases['photo'], '📷 Photo');
    expect(cases['voice'], '🎤 Voice message');
    expect(cases['video'], '🎥 Video');
    expect(cases['gif'], 'GIF');
    expect(cases['data-epoch-ignored'], 'the text');
    for (final n in [
      'reaction', 'untrusted-device', 'revoked-device', 'wrong-user', 'missing-epoch', 'bad-signature',
      'tampered-ct-resigned', 'v-bool', 'epoch-float', 'padded-b64', 'env-not-json', 'no-preview-flag',
    ]) {
      expect(cases[n], isNull, reason: n);
    }
  });
}
