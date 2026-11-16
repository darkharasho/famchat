import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:material_ui/material_ui.dart';

import 'audio_init.dart';
import 'router.dart';
import 'session/invite_link.dart';
import 'session/session_controller.dart';
import 'theme/app_theme.dart';
import 'voice/voice_io.dart';

void main() {
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
  runApp(ProviderScope(
    overrides: [initialInviteTokenProvider.overrideWithValue(invite)],
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
      routerConfig: ref.watch(routerProvider),
    );
  }
}
