import 'package:famchat/push/notification_settings.dart';
import 'package:famchat/push/notifications.dart' show PushController;
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

class FakePushController extends PushController {
  FakePushController()
    : super(
        messaging: FakeMessaging(),
        register: (_, _) async {},
        previewsOn: () async => false,
        openRoute: (_) {},
        isChatVisible: (_) => false,
        showInApp: (_, _) {},
        enrich: (m) async => m,
        askNow: false,
      );
  final calls = <bool>[];
  @override
  Future<void> setPreviews(bool on) async => calls.add(on);
}

const switchKey = Key('settings-previews');

Future<FakePreviews> pump(WidgetTester t, {PushMessaging? push, bool local = true, PushController? controller}) async {
  final previews = FakePreviews();
  final List<Override> overrides = [
    pushMessagingProvider.overrideWithValue(push),
    localNotifierProvider.overrideWithValue(local ? FakeNotifier() : null),
    pushControllerProvider.overrideWithValue(controller),
    previewsOnProvider.overrideWith(() => previews),
  ];
  await t.pumpWidget(
    ProviderScope(
      overrides: overrides,
      child: const MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: NotificationSettingsGroup())),
      ),
    ),
  );
  await t.pump();
  return previews;
}

/// [testWidgets] on [platform]. The override is reset inside the test body: the framework checks
/// debug variables before any tearDown runs.
void testOn(String name, TargetPlatform platform, Future<void> Function(WidgetTester t) body) {
  testWidgets(name, (t) async {
    debugDefaultTargetPlatformOverride = platform;
    try {
      await body(t);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

void main() {
  testOn('shows the switch (off) with its copy when local notifications are available', TargetPlatform.linux, (
    t,
  ) async {
    await pump(t);
    expect(find.byKey(switchKey), findsOneWidget);
    expect(find.text('Show message previews'), findsOneWidget);
    expect(find.text('Show what messages say. Only this device can read them.'), findsOneWidget);
    expect(t.widget<SwitchListTile>(find.byKey(switchKey)).value, isFalse);
  });

  testOn('shows the switch when push is available', TargetPlatform.android, (t) async {
    await pump(t, push: FakeMessaging(), local: false);
    expect(find.byKey(switchKey), findsOneWidget);
  });

  testOn('is shown on iOS', TargetPlatform.iOS, (t) async {
    await pump(t, push: FakeMessaging());
    expect(find.byKey(switchKey), findsOneWidget);
  });

  testOn('is absent when notifications are not available', TargetPlatform.android, (t) async {
    await pump(t, local: false);
    expect(find.byKey(switchKey), findsNothing);
  });

  testOn('toggling stores the new value', TargetPlatform.linux, (t) async {
    final previews = await pump(t);
    await t.tap(find.byKey(switchKey));
    await t.pump();
    expect(previews.sets, [true]);
    expect(t.widget<SwitchListTile>(find.byKey(switchKey)).value, isTrue);
  });

  testOn('on Android, toggling also tells the server through the push controller', TargetPlatform.android, (t) async {
    final controller = FakePushController();
    final previews = await pump(t, push: FakeMessaging(), local: false, controller: controller);
    await t.tap(find.byKey(switchKey));
    await t.pump();
    expect(previews.sets, [true]);
    expect(controller.calls, [true]);
  });

  testOn(
    'on Android without notification permission, toggling stores the value but registers nothing',
    TargetPlatform.android,
    (t) async {
      final messaging = FakeMessaging()..grantOnRequest = false;
      final registered = <(String, bool)>[];
      final controller = PushController(
        messaging: messaging,
        register: (token, previews) async => registered.add((token, previews)),
        previewsOn: () async => false,
        openRoute: (_) {},
        isChatVisible: (_) => false,
        showInApp: (_, _) {},
        enrich: (m) async => m,
        askNow: false,
      );
      final previews = await pump(t, push: messaging, local: false, controller: controller);
      await t.tap(find.byKey(switchKey));
      await t.pump();
      expect(previews.sets, [true]);
      expect(registered, isEmpty);
    },
  );
}
