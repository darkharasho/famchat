import 'dart:async';

import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:video_player_media_kit/video_player_media_kit.dart';

/// Sets up the media_kit (libmpv) backend that just_audio and video_player need on Linux and
/// Windows. Returns the error instead of throwing, so a missing libmpv disables audio and video
/// playback rather than crashing the app at startup.
Object? initAudioBackend({void Function()? init}) {
  try {
    (init ??
        () {
          JustAudioMediaKit.ensureInitialized(linux: true, windows: true);
          VideoPlayerMediaKit.ensureInitialized(linux: true, windows: true);
        })();
    return null;
  } catch (e) {
    return e;
  }
}

/// Runs a native audio [dispose] (player or recorder) but waits at most [timeout] for it, and never
/// throws. libmpv under xvfb has hung in dispose; a leaked native player beats a frozen app or test.
Future<void> disposeWithin(Future<void> Function() dispose, {Duration timeout = const Duration(seconds: 3)}) async {
  try {
    await Future.sync(dispose).timeout(timeout);
  } catch (_) {
    // timed out or failed: nothing more to do
  }
}
