import 'package:famchat/push/preview_setting.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  setUp(
    () => SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty(),
  );

  test('previews are off by default', () async {
    expect(await readPreviewsOn(), isFalse);
  });

  test('a written value is read back', () async {
    await writePreviewsOn(true);
    expect(await readPreviewsOn(), isTrue);
    await writePreviewsOn(false);
    expect(await readPreviewsOn(), isFalse);
  });

  test('uses the given prefs and the shared key', () async {
    final prefs = SharedPreferencesAsync();
    await writePreviewsOn(true, prefs);
    expect(await prefs.getBool(previewsPrefKey), isTrue);
    expect(previewsPrefKey, 'notification_previews');
  });

  test('supported on android and desktop, not iOS or web', () {
    expect(previewsSupported(platform: TargetPlatform.android), isTrue);
    expect(previewsSupported(platform: TargetPlatform.macOS), isTrue);
    expect(previewsSupported(platform: TargetPlatform.windows), isTrue);
    expect(previewsSupported(platform: TargetPlatform.linux), isTrue);
    expect(previewsSupported(platform: TargetPlatform.iOS), isFalse);
    expect(previewsSupported(platform: TargetPlatform.fuchsia), isFalse);
    expect(
      previewsSupported(web: true, platform: TargetPlatform.android),
      isFalse,
    );
  });
}
