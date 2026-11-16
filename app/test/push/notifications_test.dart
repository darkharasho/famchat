import 'dart:async';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:famchat/chat/db/chat_db.dart';
import 'package:famchat/chat/wire.dart';
import 'package:famchat/push/firebase_options.dart';
import 'package:famchat/push/notification_settings.dart' show pushTestSummary, runNotificationTest;
import 'package:famchat/push/local_notifier.dart';
import 'package:famchat/push/notifications.dart';
import 'package:famchat/push/push_messaging.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

const chatA = '01ARZ3NDEKTSV4RRFFQ69G5FAV';
const chatB = '01BX5ZZKBKACTAV9WEVGEMMVRZ';

class FakeMessaging implements PushMessaging {
  bool granted = false;
  bool grantOnRequest = true;
  int requests = 0;
  String? token = 'tok-1';
  PushMessage? initial;
  final opened = StreamController<PushMessage>.broadcast();
  final foreground = StreamController<PushMessage>.broadcast();
  final refresh = StreamController<String>.broadcast();

  @override
  Future<bool> requestPermission() async {
    requests++;
    if (grantOnRequest) granted = true;
    return granted;
  }

  @override
  Future<bool> permissionGranted() async => granted;
  @override
  Future<String?> getToken() async => token;
  @override
  Stream<String> get onTokenRefresh => refresh.stream;
  @override
  Stream<PushMessage> get onMessage => foreground.stream;
  @override
  Stream<PushMessage> get onMessageOpenedApp => opened.stream;
  @override
  Future<PushMessage?> getInitialMessage() async => initial;
}

class Harness {
  Harness({bool askNow = true, this.visible}) {
    controller = PushController(
      messaging: messaging,
      register: (t) async {
        if (failRegister) throw Exception('offline');
        registered.add(t);
      },
      openRoute: routes.add,
      isChatVisible: (id) => id == visible,
      showInApp: (m, route) => shown.add((m, route)),
      askNow: askNow,
    );
  }

  final messaging = FakeMessaging();
  final registered = <String>[];
  final routes = <String>[];
  final shown = <(PushMessage, String?)>[];
  String? visible;
  bool failRegister = false;
  late final PushController controller;
}

Future<void> settle() => Future<void>.delayed(Duration.zero);

class FakeNotifier implements LocalNotifier {
  FakeNotifier({this.allowed = true});
  final bool allowed;
  final shown = <(int, String, String, String)>[];
  @override
  bool get needsPermission => false;
  @override
  Future<void> init(void Function(String route) onTap) async {}
  @override
  Future<bool> requestPermission() async => allowed;
  @override
  Future<void> show({required int id, required String title, required String body, required String route}) async =>
      shown.add((id, title, body, route));
}

ChatDto chat(String id, String kind, {String? title, List<String> members = const ['me', 'mom']}) => ChatDto(
      id: id,
      kind: kind,
      title: title,
      createdBy: 'me',
      currentEpoch: 1,
      epochReady: true,
      lastSeq: 0,
      lastMessageAt: null,
      createdAt: 1,
      members: [for (final m in members) MemberDto(userId: m, joinedSeq: 0, lastReadSeq: 0)],
    );

UserRow user(String id, String name) =>
    UserRow(id: id, name: name, isAdmin: false, identityPub: 'x', trustedIdentityPub: 'x', knownIdentityPubs: '[]', pinnedAdmin: false);

Map<String, Object?> msg(String chatId, String sender) => {
      'type': 'msg',
      'message': {'chatId': chatId, 'seq': 1, 'id': 'm', 'senderUserId': sender, 'senderDeviceId': 'd', 'envelope': {}, 'createdAt': 1},
    };

void main() {
  group('push stays off', () {
    test('options that throw UnsupportedError (the placeholder, or a platform without push) mean none', () {
      expect(firebaseOptions(() => throw UnsupportedError('not configured')), isNull);
      // The committed placeholder, or (after scripts/setup-firebase.sh) real options on Android.
      expect(() => firebaseOptions(() => DefaultFirebaseOptions.currentPlatform), returnsNormally);
    });

    test('initPush without options never starts Firebase', () async {
      var started = false;
      final p = await initPush(pushPlatform: true, options: () => null, initialize: (_) async => started = true);
      expect(p, isNull);
      expect(started, isFalse);
    });

    test('initPush on a desktop platform is off even with options', () async {
      var started = false;
      final p = await initPush(
        pushPlatform: false,
        options: () => const FirebaseOptions(apiKey: 'k', appId: 'a', messagingSenderId: 's', projectId: 'famchat'),
        initialize: (_) async => started = true,
      );
      expect(p, isNull);
      expect(started, isFalse);
    });

    test('initPush with options starts Firebase, and a failure turns push off', () async {
      const o = FirebaseOptions(apiKey: 'k', appId: 'a', messagingSenderId: 's', projectId: 'famchat');
      expect(await initPush(pushPlatform: true, options: () => o, initialize: (_) async {}), isA<FirebasePushMessaging>());
      expect(await initPush(pushPlatform: true, options: () => o, initialize: (_) async => throw Exception('bad')), isNull);
    });

    test('push platforms are Android, iOS and the web', () {
      expect(isPushPlatform(web: true, platform: TargetPlatform.linux), isTrue);
      expect(isPushPlatform(web: false, platform: TargetPlatform.android), isTrue);
      expect(isPushPlatform(web: false, platform: TargetPlatform.iOS), isTrue);
      for (final p in [TargetPlatform.macOS, TargetPlatform.windows, TargetPlatform.linux]) {
        expect(isPushPlatform(web: false, platform: p), isFalse);
      }
    });
  });

  group('PushController', () {
    test('phones ask at start and register the token and its refreshes', () async {
      final h = Harness();
      await h.controller.start();
      expect(h.messaging.requests, 1);
      expect(h.registered, ['tok-1']);
      h.messaging.refresh.add('tok-2');
      await settle();
      expect(h.registered, ['tok-1', 'tok-2']);
      await h.controller.stop();
      h.messaging.refresh.add('tok-3');
      await settle();
      expect(h.registered, ['tok-1', 'tok-2']);
    });

    test('denied permission registers nothing', () async {
      final h = Harness()..messaging.grantOnRequest = false;
      await h.controller.start();
      expect(h.registered, isEmpty);
    });

    test('the web waits for the button unless already allowed', () async {
      final h = Harness(askNow: false);
      await h.controller.start();
      expect(h.messaging.requests, 0);
      expect(h.registered, isEmpty);
      expect(await h.controller.enable(), isTrue);
      expect(h.registered, ['tok-1']);

      final again = Harness(askNow: false)..messaging.granted = true;
      await again.controller.start();
      expect(again.registered, ['tok-1']);
    });

    test('an offline registration does not break start', () async {
      final h = Harness()..failRegister = true;
      await h.controller.start();
      expect(h.registered, isEmpty);
    });

    test('the tap that launched the app opens its chat', () async {
      final h = Harness()..messaging.initial = const PushMessage(chatId: chatA);
      await h.controller.start();
      expect(h.routes, ['/chats/$chatA']);
    });

    test('a tap while running opens its chat; junk chat ids are ignored', () async {
      final h = Harness();
      await h.controller.start();
      h.messaging.opened.add(const PushMessage(chatId: chatB));
      h.messaging.opened.add(const PushMessage(chatId: '../devices'));
      h.messaging.opened.add(const PushMessage());
      await settle();
      expect(h.routes, ['/chats/$chatB']);
    });

    test('foreground message for the open chat is suppressed, others shown in the app', () async {
      final h = Harness(visible: chatA);
      await h.controller.start();
      h.messaging.foreground.add(const PushMessage(chatId: chatA, title: 'Mom', body: 'New message'));
      h.messaging.foreground.add(const PushMessage(chatId: chatB, title: 'Parents', body: 'New message from Dad'));
      h.messaging.foreground.add(const PushMessage(title: 'FamChat', body: 'Test notification'));
      await settle();
      expect(h.shown.map((s) => (s.$1.title, s.$2)), [('Parents', '/chats/$chatB'), ('FamChat', null)]);
    });
  });

  group('socket notifications', () {
    late ChatDb db;
    setUp(() async {
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
      db = ChatDb(NativeDatabase.memory());
      await db.putUser(user('mom', 'Mom'));
      await db.putUser(user('dad', 'Dad'));
      await db.upsertChat(chat(chatA, 'direct'));
      await db.upsertChat(chat(chatB, 'group', title: 'Parents', members: ['me', 'mom', 'dad']));
    });
    tearDown(() => db.close());

    test('notificationText names who and where, never what', () async {
      expect(await notificationText(db, chatA, 'mom'), ('Mom', 'New message'));
      expect(await notificationText(db, chatB, 'dad'), ('Parents', 'New message from Dad'));
      expect(await notificationText(db, '01CQ5ZZKBKACTAV9WEVGEMMVRZ', 'ghost'), ('Someone', 'New message'));
    });

    test('messages from others notify while the app is not in front', () async {
      final events = StreamController<Map<String, Object?>>.broadcast();
      final notifier = FakeNotifier();
      var front = false;
      final n = MessageNotifier(events: events.stream, myUserId: 'me', db: db, notifier: notifier, inFront: () => front)
        ..start();
      events.add(msg(chatB, 'dad'));
      events.add(msg(chatB, 'me')); // my own other device
      events.add({'type': 'typing', 'chatId': chatB, 'userId': 'dad'});
      await Future<void>.delayed(const Duration(milliseconds: 50));
      front = true;
      events.add(msg(chatA, 'mom'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(notifier.shown.map((s) => (s.$2, s.$3, s.$4)), [('Parents', 'New message from Dad', '/chats/$chatB')]);
      await n.stop();
      await events.close();
    });
  });

  test('pushTestSummary', () {
    expect(pushTestSummary(null), "Push isn't set up on the server yet.");
    expect(pushTestSummary({'configured': false, 'devices': []}), "Push isn't set up on the server yet.");
    expect(pushTestSummary({'configured': true, 'devices': []}), 'None of your devices has notifications turned on.');
    expect(
      pushTestSummary({
        'configured': true,
        'devices': [
          {'id': 'a', 'name': 'Pixel', 'result': 'ok'},
          {'id': 'b', 'name': 'iPad', 'result': 'stale'},
        ],
      }),
      'Sent to 1 of 2 devices. Not delivered: iPad.',
    );
    expect(pushTestSummary({'configured': true, 'error': 'oauth_failed', 'devices': []}), "The server couldn't reach Firebase.");
  });

  test("pushTestSummary says when this device didn't register, even if another device got the push", () {
    // iOS 1.0.3: the phone had no APNs token, the test went to a web tab, and the phone said "Sent to 1 of 1 device."
    final ok = {
      'configured': true,
      'devices': [
        {'id': 'a', 'name': 'Chrome', 'result': 'ok'},
      ],
    };
    expect(pushTestSummary(ok), 'Sent to 1 of 1 device.');
    expect(pushTestSummary(ok, thisDevice: false), startsWith("This device isn't registered for notifications"));
    expect(pushTestSummary(ok, thisDevice: false), endsWith('Sent to 1 of 1 device.'));
    expect(pushTestSummary({'configured': false}, thisDevice: false), "Push isn't set up on the server yet.");
  });

  group('runNotificationTest', () {
    test('push devices register first and pass whether that worked to the summary', () async {
      final h = Harness();
      h.messaging.token = null; // iOS without an APNs token
      var asked = 0;
      final text = await runNotificationTest(
        push: h.controller,
        local: null,
        sendServerTest: () async {
          asked++;
          return {'configured': true, 'devices': []};
        },
      );
      expect(asked, 1);
      expect(text, startsWith("This device isn't registered for notifications"));
    });

    test('desktop apps (no push) show a local test notification', () async {
      final notifier = FakeNotifier();
      final text = await runNotificationTest(
        push: null,
        local: notifier,
        sendServerTest: () async => fail('desktop has no push'),
      );
      expect(notifier.shown.map((s) => (s.$2, s.$3)), [('FamChat', 'Test notification')]);
      expect(text, 'Sent a test notification to this device.');
    });

    test("desktop apps say so when notifications can't show", () async {
      final notifier = FakeNotifier(allowed: false);
      final text = await runNotificationTest(push: null, local: notifier, sendServerTest: () async => null);
      expect(notifier.shown, isEmpty);
      expect(text, startsWith("This device can't show notifications"));
    });
  });
}
