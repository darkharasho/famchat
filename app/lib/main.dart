import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:material_ui/material_ui.dart';

import 'audio_init.dart';
import 'router.dart';

void main() {
  // Web: real paths (famchat.dev/join), not #/join. The Worker serves index.html for app routes.
  usePathUrlStrategy();
  WidgetsFlutterBinding.ensureInitialized();
  // just_audio has no Linux/Windows backend of its own; media_kit (libmpv) provides it.
  // If libmpv is missing, only audio playback is lost.
  final audioErr = initAudioBackend();
  if (audioErr != null) debugPrint('audio backend unavailable: $audioErr');
  runApp(const ProviderScope(child: FamChatApp()));
}

class FamChatApp extends StatelessWidget {
  const FamChatApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'FamChat',
      theme: ThemeData(colorSchemeSeed: Colors.indigo),
      darkTheme: ThemeData(colorSchemeSeed: Colors.indigo, brightness: Brightness.dark),
      routerConfig: appRouter,
    );
  }
}
