import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:material_ui/material_ui.dart';

import 'audio_init.dart';
import 'push/providers.dart';
import 'push/push_messaging.dart';
import 'router.dart';
import 'session/invite_link.dart';
import 'session/session_controller.dart';
import 'theme/app_theme.dart';
import 'update/update_banner.dart';
import 'voice/voice_io.dart';
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
  final invite = kIsWeb ? inviteTokenFromUri(Uri.base) : null;
  // FCM on Android, iOS and the web once Firebase is configured; otherwise null and push is off.
  final push = await initPush();
  runApp(ProviderScope(
    overrides: [
      initialInviteTokenProvider.overrideWithValue(invite),
      pushMessagingProvider.overrideWithValue(push),
    ],
    child: const FamChatApp(),
  ));
}

final _light = buildTheme(Brightness.light);
final _dark = buildTheme(Brightness.dark);

class FamChatApp extends ConsumerWidget {
  const FamChatApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp.router(
      title: 'FamChat',
      debugShowCheckedModeBanner: false,
      theme: _light,
      darkTheme: _dark,
      // Foreground pushes show as snack bars over any screen.
      scaffoldMessengerKey: ref.watch(rootMessengerKeyProvider),
      routerConfig: ref.watch(routerProvider),
      // FamChat's own title bar over every screen on the desktop apps; nothing elsewhere.
      // The update popup floats over every screen.
      builder: (context, child) => WindowFrame(
        child: Stack(children: [child ?? const SizedBox.shrink(), const UpdatePrompt()]),
      ),
    );
  }
}
