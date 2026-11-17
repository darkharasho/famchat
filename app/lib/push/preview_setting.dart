// The per-device "Show message previews" setting. Stored locally with SharedPreferencesAsync (not
// the cached SharedPreferences) so a background isolate on Android reads the current value.
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const previewsPrefKey = 'notification_previews';

/// Off unless the user turned it on.
Future<bool> readPreviewsOn([SharedPreferencesAsync? prefs]) async =>
    await (prefs ?? SharedPreferencesAsync()).getBool(previewsPrefKey) ?? false;

Future<void> writePreviewsOn(bool on, [SharedPreferencesAsync? prefs]) =>
    (prefs ?? SharedPreferencesAsync()).setBool(previewsPrefKey, on);

/// Stage 1: Android and desktop. Not iOS, not the web.
bool previewsSupported({bool web = kIsWeb, TargetPlatform? platform}) {
  if (web) return false;
  switch (platform ?? defaultTargetPlatform) {
    case TargetPlatform.android:
    case TargetPlatform.macOS:
    case TargetPlatform.windows:
    case TargetPlatform.linux:
      return true;
    case TargetPlatform.iOS:
    case TargetPlatform.fuchsia:
      return false;
  }
}

class PreviewsOnNotifier extends AsyncNotifier<bool> {
  @override
  Future<bool> build() => readPreviewsOn();

  Future<void> set(bool on) async {
    await writePreviewsOn(on);
    state = AsyncData(on);
  }
}

final previewsOnProvider = AsyncNotifierProvider<PreviewsOnNotifier, bool>(
  PreviewsOnNotifier.new,
);
