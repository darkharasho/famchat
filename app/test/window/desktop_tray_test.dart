import 'dart:async';

import 'package:famchat/chat/db/chat_db.dart';
import 'package:famchat/chat/providers.dart';
import 'package:famchat/push/app_badge.dart';
import 'package:famchat/settings/close_to_tray.dart';
import 'package:famchat/window/desktop_badges.dart';
import 'package:famchat/window/desktop_tray.dart';
import 'package:famchat/window/desktop_window.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import '../chat/unread_total_test.dart' show item;
import 'fake_desktop_window.dart';

/// Waits for async work that really runs (rendering), not just microtasks.
Future<void> settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty());

  test('desktopPlatform: Windows, macOS and Linux apps only', () {
    for (final p in [TargetPlatform.windows, TargetPlatform.macOS, TargetPlatform.linux]) {
      expect(desktopPlatform(web: false, platform: p), p);
    }
    expect(desktopPlatform(web: false, platform: TargetPlatform.android), isNull);
    expect(desktopPlatform(web: true, platform: TargetPlatform.windows), isNull);
  });

  group('badge payloads', () {
    final art = DesktopBadgeArt();

    test('Linux: the launcher count', () async {
      expect(await badgePayload(TargetPlatform.linux, 12, art), {'count': 12});
      expect(await badgePayload(TargetPlatform.linux, 0, art), {'count': 0});
    });

    test('Windows: no overlay at 0; a described overlay at every size otherwise', () async {
      expect(await badgePayload(TargetPlatform.windows, 0, art), {'description': '', 'icons': null});
      final p = (await badgePayload(TargetPlatform.windows, 3, art))!;
      expect(p['description'], '3 unread');
      final icons = p['icons']! as List<Map<String, Object?>>;
      expect(icons.map((i) => i['size']), [16, 20, 24, 32, 40, 48, 64]);
      for (final i in icons) {
        expect((i['pixels']! as Uint8List).length, (i['size']! as int) * (i['size']! as int) * 4);
      }
    });

    test('macOS: none (app_badge_plus sets the Dock)', () async {
      expect(await badgePayload(TargetPlatform.macOS, 3, art), isNull);
    });

    test('tray: hidden, or the icon with its tooltip; macOS gets a glyph and a title', () async {
      expect(await trayPayload(TargetPlatform.windows, visible: false, count: 4, art: art), {'visible': false});
      final win = await trayPayload(TargetPlatform.windows, visible: true, count: 4, art: art);
      expect(win['tooltip'], 'FamChat — 4 unread');
      expect(win['icons'], hasLength(7));
      final mac = await trayPayload(TargetPlatform.macOS, visible: true, count: 14, art: art);
      expect(mac['title'], '9+');
      expect(mac['icon'], isA<Uint8List>());
      final mac0 = await trayPayload(TargetPlatform.macOS, visible: true, count: 0, art: art);
      expect(mac0['title'], '');
      expect(mac0['tooltip'], 'FamChat');
    });
  });

  test('LatestOnly drops an update overtaken by a newer one', () async {
    final sent = <int>[];
    final latest = LatestOnly();
    final slow = Completer<int>();
    final first = latest.run(() => slow.future, sent.add);
    await latest.run(() async => 2, sent.add);
    slow.complete(1);
    await first;
    expect(sent, [2]);
  });

  group('desktopTrayProvider', () {
    late StreamController<List<ChatListItem>> list;
    late FakeDesktopWindow window;

    ProviderContainer start(TargetPlatform platform, {bool? closeToTray}) {
      final c = ProviderContainer(overrides: [
        desktopPlatformProvider.overrideWithValue(platform),
        desktopWindowProvider.overrideWithValue(window),
        chatListProvider.overrideWith((ref) => list.stream),
        myUserIdProvider.overrideWith((ref) => 'me'),
      ]);
      addTearDown(c.dispose);
      c.listen(desktopTrayProvider, (_, _) {});
      c.listen(appBadgeProvider, (_, _) {});
      return c;
    }

    setUp(() {
      list = StreamController<List<ChatListItem>>();
      window = FakeDesktopWindow();
    });

    test('Windows: close to tray on by default, tray icon follows the count', () async {
      start(TargetPlatform.windows);
      await settle();
      expect(window.closeToTray.last, isTrue);
      expect(window.trays.last['visible'], isTrue);
      expect(window.trays.last['tooltip'], 'FamChat');
      list.add([item('a', 2), item('b', 1)]);
      await settle();
      expect(window.trays.last['tooltip'], 'FamChat — 3 unread');
      expect(window.badges.last['description'], '3 unread');
      list.add([item('a', 0)]);
      await settle();
      expect(window.trays.last['tooltip'], 'FamChat');
      expect(window.badges.last['icons'], isNull);
    });

    test('Linux: off by default, so no tray icon; the launcher count still follows', () async {
      final c = start(TargetPlatform.linux);
      list.add([item('a', 5)]);
      await settle();
      expect(window.closeToTray, [false]);
      expect(window.trays, isEmpty);
      expect(window.badges.last, {'count': 5});
      // Switched on: the icon appears and closing hides.
      await c.read(closeToTrayProvider.notifier).set(true);
      await settle();
      expect(window.closeToTray.last, isTrue);
      expect(window.trays.last['visible'], isTrue);
      // The tray host goes away: closing quits again and the icon is taken down.
      window.trayAvailable.value = false;
      await settle();
      expect(window.closeToTray.last, isFalse);
      expect(window.trays.last, {'visible': false});
    });

    test('does nothing off the desktop', () async {
      final c = ProviderContainer(overrides: [
        desktopPlatformProvider.overrideWithValue(null),
        desktopWindowProvider.overrideWithValue(null),
      ]);
      addTearDown(c.dispose);
      c.read(desktopTrayProvider);
      expect(window.closeToTray, isEmpty);
    });
  });
}
