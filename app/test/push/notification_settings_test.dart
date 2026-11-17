import 'package:famchat/push/notification_settings.dart';
import 'package:famchat/push/preview_setting.dart';
import 'package:famchat/push/providers.dart';
import 'package:famchat/push/push_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'notifications_test.dart' show FakeMessaging, FakeNotifier;

class FakePreviews extends PreviewsOnNotifier {
  final sets = <bool>[];
  @override
  Future<bool> build() async => false;
  @override
  Future<void> set(bool on) async {
    sets.add(on);
    state = AsyncData(on);
  }
}

const switchKey = Key('settings-previews');

Future<FakePreviews> pump(
  WidgetTester t, {
  PushMessaging? push,
  bool local = true,
}) async {
  final previews = FakePreviews();
  final List<Override> overrides = [
    pushMessagingProvider.overrideWithValue(push),
    localNotifierProvider.overrideWithValue(local ? FakeNotifier() : null),
    pushControllerProvider.overrideWithValue(null),
    previewsOnProvider.overrideWith(() => previews),
  ];
  await t.pumpWidget(
    ProviderScope(
      overrides: overrides,
      child: const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: NotificationSettingsGroup()),
        ),
      ),
    ),
  );
  await t.pump();
  // Reset before the test ends: the framework checks debug variables ahead of tearDown.
  addTearDown(() => debugDefaultTargetPlatformOverride = null);
  return previews;
}

void main() {
  testWidgets(
    'shows the switch (off) with its copy when local notifications are available',
    (t) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      await pump(t);
      expect(find.byKey(switchKey), findsOneWidget);
      expect(find.text('Show message previews'), findsOneWidget);
      expect(
        find.text('Show what messages say. Only this device can read them.'),
        findsOneWidget,
      );
      expect(t.widget<SwitchListTile>(find.byKey(switchKey)).value, isFalse);
    },
  );

  testWidgets('shows the switch when push is available', (t) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await pump(t, push: FakeMessaging(), local: false);
    expect(find.byKey(switchKey), findsOneWidget);
  });

  testWidgets('is absent on iOS', (t) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    await pump(t, push: FakeMessaging());
    expect(find.byKey(switchKey), findsNothing);
  });

  testWidgets('is absent when notifications are not available', (t) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await pump(t, local: false);
    expect(find.byKey(switchKey), findsNothing);
  });

  testWidgets('toggling stores the new value', (t) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    final previews = await pump(t);
    await t.tap(find.byKey(switchKey));
    await t.pump();
    expect(previews.sets, [true]);
    expect(t.widget<SwitchListTile>(find.byKey(switchKey)).value, isTrue);
  });
}
