import 'package:famchat/session/secure_kv.dart';
import 'package:famchat/settings/appearance.dart';
import 'package:famchat/theme/app_theme.dart';
import 'package:famchat/theme/presets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import '../support/app_harness.dart';
import '../support/fake_server.dart';

void main() {
  setUp(() => SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty());

  group('storage', () {
    test('nothing stored: System and Porch light', () async {
      expect(await readAppearance(), const Appearance());
      expect((await readAppearance()).mode, ThemeMode.system);
      expect((await readAppearance()).preset, same(ThemePreset.porchLight));
    });

    test('a choice round-trips', () async {
      await writeAppearance(const Appearance(mode: ThemeMode.dark, preset: ThemePreset.forest));
      final a = await readAppearance();
      expect(a.mode, ThemeMode.dark);
      expect(a.preset, same(ThemePreset.forest));
    });

    test('an unknown preset id or mode falls back to the default', () async {
      final prefs = SharedPreferencesAsync();
      await prefs.setString(themePresetPrefKey, 'neon-retired');
      await prefs.setString(themeModePrefKey, 'sepia');
      final a = await readAppearance();
      expect(a.preset, same(ThemePreset.porchLight));
      expect(a.mode, ThemeMode.system);
    });
  });

  group('the Appearance screen', () {
    late FakeServer server;
    setUp(() => server = FakeServer());

    ColorScheme schemeOnScreen(WidgetTester tester) =>
        Theme.of(tester.element(find.text('Appearance').first)).colorScheme;

    Future<void> openAppearance(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1000, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await pumpApp(tester, server: server, kv: MemorySecureKv());
      await signInDirectly(tester, server, name: 'Gran');
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.byKey(const Key('settings-appearance')), 100);
      await tester.pumpAndSettle();
      expect(find.text('Porch light, follows the system'), findsOneWidget);
      await tester.tap(find.byKey(const Key('settings-appearance')));
      await tester.pumpAndSettle();
    }

    testWidgets('choosing a preset and a mode applies at once and is saved on the device', (tester) async {
      await openAppearance(tester);
      expect(schemeOnScreen(tester), schemeFor(Brightness.light)); // the test device is light

      await tester.tap(find.byKey(const Key('appearance-preset-ocean')));
      await tester.pumpAndSettle();
      expect(schemeOnScreen(tester), schemeFor(Brightness.light, ThemePreset.ocean));
      expect(
        tester.getSemantics(find.byKey(const Key('appearance-preset-ocean'))),
        isSemantics(isSelected: true, isButton: true, label: 'Ocean colours. Deep navy and sea glass'),
      );

      await tester.tap(find.byKey(const Key('appearance-mode-dark')));
      await tester.pumpAndSettle();
      expect(schemeOnScreen(tester), schemeFor(Brightness.dark, ThemePreset.ocean));

      final saved = await readAppearance();
      expect(saved.preset, same(ThemePreset.ocean));
      expect(saved.mode, ThemeMode.dark);

      // Back in Settings, the row says what's chosen.
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.byKey(const Key('settings-appearance')), 100);
      expect(find.text('Ocean, always dark'), findsOneWidget);
    });

    testWidgets('the app opens in the theme main() read from the device', (tester) async {
      await pumpApp(
        tester,
        server: server,
        kv: MemorySecureKv(),
        extra: [
          initialAppearanceProvider.overrideWithValue(
            const Appearance(mode: ThemeMode.dark, preset: ThemePreset.sunset),
          ),
        ],
      );
      final scheme = Theme.of(tester.element(find.byType(Scaffold).first)).colorScheme;
      expect(scheme, schemeFor(Brightness.dark, ThemePreset.sunset));
    });

    testWidgets('every preset has a labelled, selectable card', (tester) async {
      await openAppearance(tester);
      for (final p in ThemePreset.all) {
        final card = find.byKey(Key('appearance-preset-${p.id}'));
        await tester.scrollUntilVisible(card, 100);
        expect(find.bySemanticsLabel(RegExp('^${p.name} colours')), findsOneWidget);
        await tester.tap(card);
        await tester.pumpAndSettle();
        expect(schemeOnScreen(tester).surface, p.light.surface, reason: p.name);
      }
    });
  });
}
