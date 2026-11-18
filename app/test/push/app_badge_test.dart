import 'dart:async';

import 'package:famchat/chat/db/chat_db.dart';
import 'package:famchat/chat/providers.dart';
import 'package:famchat/push/app_badge.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chat/unread_total_test.dart' show item, t0;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('only the Android and iOS apps have a badge', () {
    expect(isBadgePlatform(web: false, platform: TargetPlatform.android), isTrue);
    expect(isBadgePlatform(web: false, platform: TargetPlatform.iOS), isTrue);
    expect(isBadgePlatform(web: true, platform: TargetPlatform.android), isFalse);
    for (final p in [TargetPlatform.macOS, TargetPlatform.windows, TargetPlatform.linux]) {
      expect(isBadgePlatform(web: false, platform: p), isFalse);
    }
  });

  group('appBadgeProvider', () {
    late StreamController<List<ChatListItem>> list;
    late List<int> set;
    late String? me;

    ProviderContainer container({bool phone = true}) {
      final c = ProviderContainer(overrides: [
        chatListProvider.overrideWith((ref) => list.stream),
        myUserIdProvider.overrideWith((ref) => me),
        appBadgeSetterProvider.overrideWithValue(phone ? (n) async => set.add(n) : null),
      ]);
      addTearDown(c.dispose);
      c.listen(appBadgeProvider, (_, _) {});
      return c;
    }

    setUp(() {
      list = StreamController<List<ChatListItem>>();
      set = [];
      me = 'me';
    });

    test('waits for the chat list, then keeps the badge equal to the unread total', () async {
      container();
      await pumpEventQueue();
      expect(set, isEmpty); // a badge a push set isn't cleared before the count is known
      list.add([item('a', 2), item('b', 3, mutedUntil: t0.add(const Duration(days: 3650)))]);
      await pumpEventQueue();
      list.add([item('a', 1), item('b', 3, mutedUntil: t0.add(const Duration(days: 3650)))]);
      await pumpEventQueue();
      list.add([item('a', 0)]);
      await pumpEventQueue();
      expect(set, [2, 1, 0]);
    });

    test('sets it again when the app returns to the foreground', () async {
      container();
      list.add([item('a', 4)]);
      await pumpEventQueue();
      TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(set, [4, 4]);
    });

    test('signed out clears it', () async {
      me = null;
      container();
      await pumpEventQueue();
      expect(set, [0]);
    });

    test('does nothing where there is no badge', () async {
      container(phone: false);
      list.add([item('a', 4)]);
      await pumpEventQueue();
      expect(set, isEmpty);
    });
  });
}
