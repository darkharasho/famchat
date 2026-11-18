import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:material_ui/material_ui.dart';

import 'audio_init.dart';
import 'push/app_badge.dart';
import 'push/android_previews.dart';
import 'push/providers.dart';
import 'push/push_messaging.dart';
import 'router.dart';
import 'session/invite_link.dart';
import 'session/session_controller.dart';
import 'theme/app_theme.dart';
import 'theme/motion.dart';
import 'theme/presets.dart';
import 'theme/system_bars.dart';
import 'update/update_banner.dart';
import 'media/video_io.dart';
import 'session/app_links.dart';
import 'settings/appearance.dart';
import 'settings/time_format_tile.dart';
import 'share/share_inbox.dart';
import 'voice/voice_io.dart';
import 'window/desktop_tray.dart';
import 'window/title_bar.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // famchat.dev/join#<token>: the fragment is the invite, not a route, so use path URLs.
  usePathUrlStrategy();
  registerFontLicenses();
  // just_audio has no Linux/Windows backend of its own; media_kit (libmpv) provides it.
  // If libmpv is missing, only audio playback is lost.
  final audioErr = initAudioBackend();
  if (audioErr != null) debugPrint('audio backend unavailable: $audioErr');
  // Recordings and decrypted voice clips a crash or kill left behind.
  unawaited(sweepVoiceFiles());
  unawaited(sweepVideoFiles());
  final invite = kIsWeb ? inviteTokenFromUri(Uri.base) : null;
  // FCM on Android, iOS and the web once Firebase is configured; otherwise null and push is off.
  final push = await initPush();
  // Android with previews on: data-only pushes the app decrypts and shows itself.
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android && push != null) {
    FirebaseMessaging.onBackgroundMessage(firebaseBackgroundHandler);
  }
  // Read before the first frame so the app opens in the chosen theme, not the default.
  final appearance = await readAppearance();
  runApp(ProviderScope(
    overrides: [
      initialInviteTokenProvider.overrideWithValue(invite),
      pushMessagingProvider.overrideWithValue(push),
      initialAppearanceProvider.overrideWithValue(appearance),
    ],
    child: const FamChatApp(),
  ));
}

// Built once per preset and brightness, when first shown.
final _themes = <(String, Brightness), ThemeData>{};
ThemeData _theme(ThemePreset preset, Brightness b) => _themes.putIfAbsent((preset.id, b), () => buildTheme(b, preset));

class FamChatApp extends ConsumerWidget {
  const FamChatApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(appBadgeProvider); // the unread badge: app icon, Dock, taskbar or launcher
    ref.watch(desktopTrayProvider); // desktop: close to tray and the tray icon
    final appearance = ref.watch(appearanceProvider);
    return MaterialApp.router(
      title: 'FamChat',
      debugShowCheckedModeBanner: false,
      theme: _theme(appearance.preset, Brightness.light),
      darkTheme: _theme(appearance.preset, Brightness.dark),
      themeMode: appearance.mode,
      // A short cross-fade when the theme changes; none when motion is reduced.
      themeAnimationStyle: Motion.reduced(context)
          ? AnimationStyle.noAnimation
          : const AnimationStyle(duration: Motion.medium, curve: Curves.easeInOut),
      // Foreground pushes show as snack bars over any screen.
      scaffoldMessengerKey: ref.watch(rootMessengerKeyProvider),
      routerConfig: ref.watch(routerProvider),
      // FamChat's own title bar over every screen on the desktop apps; nothing elsewhere.
      // The update popup floats over every screen.
      // The phone's status and navigation bars follow the theme.
      builder: (context, child) => SystemBarsStyle(
        child: TimeFormatScope(
          child: WindowFrame(
            child: Stack(children: [child ?? const SizedBox.shrink(), const UpdatePrompt(), const ShareInbox(), const InviteLinkListener()]),
          ),
        ),
      ),
    );
  }
}
