import 'package:famchat/settings/close_to_tray.dart';
import 'package:famchat/settings/close_to_tray_tile.dart';
import 'package:famchat/window/desktop_window.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import '../window/fake_desktop_window.dart';

ProviderContainer container(TargetPlatform? platform, FakeDesktopWindow? window) {
  final c = ProviderContainer(overrides: [
    desktopPlatformProvider.overrideWithValue(platform),
    desktopWindowProvider.overrideWithValue(window),
  ]);
  addTearDown(c.dispose);
  return c;
}

Future<void> pumpGroup(WidgetTester t, TargetPlatform? platform, FakeDesktopWindow? window) async {
  await t.pumpWidget(ProviderScope(
    overrides: [
      desktopPlatformProvider.overrideWithValue(platform),
      desktopWindowProvider.overrideWithValue(window),
    ],
    child: const MaterialApp(home: Scaffold(body: WindowSettingsGroup())),
  ));
  await t.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty());

  test('desktop platforms: on by default on Windows, off on Linux and macOS', () {
    expect(closeToTrayDefault(TargetPlatform.windows), isTrue);
    expect(closeToTrayDefault(TargetPlatform.linux), isFalse);
    expect(closeToTrayDefault(TargetPlatform.macOS), isFalse);
    expect(closeToTrayTitle(TargetPlatform.windows), 'Close to tray');
    expect(closeToTrayTitle(TargetPlatform.linux), 'Close to tray');
    expect(closeToTrayTitle(TargetPlatform.macOS), 'Keep running in the menu bar');
  });

  test('the platform default until a choice is stored, then the choice', () async {
    expect(await readCloseToTray(TargetPlatform.windows), isTrue);
    expect(await readCloseToTray(TargetPlatform.linux), isFalse);
    await writeCloseToTray(false);
    expect(await readCloseToTray(TargetPlatform.windows), isFalse);
    await writeCloseToTray(true);
    expect(await readCloseToTray(TargetPlatform.linux), isTrue);
    expect(await SharedPreferencesAsync().getBool(closeToTrayPrefKey), isTrue);
  });

  test('the notifier reads the default and persists a change', () async {
    final c = container(TargetPlatform.linux, FakeDesktopWindow());
    expect(await c.read(closeToTrayProvider.future), isFalse);
    expect(c.read(closeToTrayActiveProvider), isFalse);
    await c.read(closeToTrayProvider.notifier).set(true);
    expect(c.read(closeToTrayActiveProvider), isTrue);
    expect(await readCloseToTray(TargetPlatform.linux), isTrue);
  });

  test('Linux without a tray host: not offered, and closing quits even when switched on', () async {
    await writeCloseToTray(true);
    final window = FakeDesktopWindow(trayAvailable: false);
    final c = container(TargetPlatform.linux, window);
    await c.read(closeToTrayProvider.future);
    expect(c.read(closeToTrayOfferedProvider), isFalse);
    expect(c.read(closeToTrayActiveProvider), isFalse);
    // A tray host starts.
    window.trayAvailable.value = true;
    expect(c.read(closeToTrayOfferedProvider), isTrue);
    expect(c.read(closeToTrayActiveProvider), isTrue);
  });

  test('phones and the web: off and not offered', () async {
    final c = container(null, null);
    expect(await c.read(closeToTrayProvider.future), isFalse);
    expect(c.read(closeToTrayOfferedProvider), isFalse);
  });

  testWidgets('Settings shows the switch on Windows, on by default, and it saves', (t) async {
    await pumpGroup(t, TargetPlatform.windows, FakeDesktopWindow());
    expect(find.text('Close to tray'), findsOneWidget);
    final tile = find.byKey(const Key('settings-close-to-tray'));
    expect(t.widget<SwitchListTile>(tile).value, isTrue);
    await t.tap(tile);
    await t.pumpAndSettle();
    expect(t.widget<SwitchListTile>(tile).value, isFalse);
    expect(await SharedPreferencesAsync().getBool(closeToTrayPrefKey), isFalse);
  });

  testWidgets('macOS words it for the menu bar', (t) async {
    await pumpGroup(t, TargetPlatform.macOS, FakeDesktopWindow());
    expect(find.text('Keep running in the menu bar'), findsOneWidget);
  });

  testWidgets('hidden on Linux without a tray host, and off the desktop', (t) async {
    await pumpGroup(t, TargetPlatform.linux, FakeDesktopWindow(trayAvailable: false));
    expect(find.byKey(const Key('settings-close-to-tray')), findsNothing);
    await pumpGroup(t, null, null);
    expect(find.byKey(const Key('settings-close-to-tray')), findsNothing);
  });
}
