import 'dart:convert';

import 'package:drift/native.dart';
import 'package:famchat/chat/db/chat_db.dart';
import 'package:famchat/chat/plaintext.dart';
import 'package:famchat/crypto/encoding.dart';
import 'package:famchat/crypto/envelope.dart';
import 'package:famchat/crypto/keys.dart';
import 'package:famchat/push/android_previews.dart';
import 'package:famchat/push/push_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

const chatId = '01ARZ3NDEKTSV4RRFFQ69G5FAV', messageId = 'M1', userId = 'bob', deviceId = 'bob-d';

void main() {
  late ChatDb db;
  late DeviceKeys sender;
  final chatKey = Uint8List.fromList(List.generate(32, (i) => i));

  setUpAll(() async => sender = await DeviceKeys.generate());
  setUp(() async {
    db = ChatDb(NativeDatabase.memory());
    await db.putDevice(DeviceRow(
      id: deviceId,
      userId: userId,
      name: 'Phone',
      encPub: 'x',
      signPub: b64url(await sender.signPub()),
      certSig: 'x',
      revoked: false,
      certValid: true,
      trusted: true,
    ));
    await db.putKey(chatId, 1, chatKey);
  });
  tearDown(() => db.close());

  /// The FCM data of a preview push, as the server sends it (every value a string).
  Future<Map<String, Object?>> data({bool preview = true}) async {
    final env = (await encryptEnvelope(
      chatKey: chatKey,
      epoch: 1,
      chatId: chatId,
      messageId: messageId,
      senderDeviceId: deviceId,
      signKey: sender.sign,
      plaintext: const TextBody('see you at 6').encode(),
    ))
        .toJson();
    return {
      'chatId': chatId,
      'messageId': messageId,
      'senderUserId': userId,
      'senderDeviceId': deviceId,
      'epoch': '1',
      'env': jsonEncode(env),
      'title': 'Bob',
      'body': 'New message',
      if (preview) 'preview': '1',
    };
  }

  Future<({String title, String body})> text(Map<String, Object?> d,
          {bool on = true, Future<ChatDb> Function()? openDb}) =>
      previewNotificationText(PushMessage.fromData(d), previewsOn: () async => on, openDb: openDb ?? () async => db);

  test('preview on and decryptable gives the text', () async {
    final m = PushMessage.fromData(await data());
    expect(m.isPreview, isTrue);
    expect(m.envelope, isNotNull);
    expect(await text(await data()), (title: 'Bob', body: 'see you at 6'));
  });

  test('previews off locally shows generic text', () async {
    expect(await text(await data(), on: false), (title: 'Bob', body: 'New message'));
  });

  test('failure falls back to generic', () async {
    expect(await text(await data(), openDb: () async => throw StateError('no db')), (title: 'Bob', body: 'New message'));
  });

  test('not a preview message gives generic', () async {
    final d = await data(preview: false);
    expect(PushMessage.fromData(d).isPreview, isFalse);
    expect(await text(d), (title: 'Bob', body: 'New message'));
  });

  test('the Android notification expands to the whole preview', () {
    const body = 'a long preview that does not fit on one line of a notification, so it must expand';
    final d = previewNotificationDetails(chatId, body);
    expect(d.styleInformation, isA<BigTextStyleInformation>().having((s) => s.bigText, 'bigText', body));
    expect((d.channelId, d.tag, d.visibility, d.importance, d.priority),
        ('messages', chatId, NotificationVisibility.private, Importance.high, Priority.high));
    expect(d.number, isNull);
    expect(previewNotificationDetails(chatId, body, badge: 4).number, 4);
  });

  test('background pushes set the badge they carry; a badge update does only that', () async {
    final set = <int>[];
    Future<void> record(int n) async => set.add(n);
    await handleBackgroundPush({'type': 'badge', 'badge': '2'}, setBadge: record);
    await handleBackgroundPush({'chatId': chatId, 'badge': '5'}, title: 'Bob', body: 'New message', setBadge: record);
    await handleBackgroundPush({'type': 'badge', 'badge': '0'}, setBadge: record);
    await handleBackgroundPush({'chatId': chatId}, title: 'Bob', body: 'New message', setBadge: record);
    expect(set, [2, 5, 0]);
  });
}
