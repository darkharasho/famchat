import 'package:just_audio_media_kit/just_audio_media_kit.dart';

/// Sets up the media_kit (libmpv) backend that just_audio needs on Linux and Windows.
/// Returns the error instead of throwing, so a missing libmpv disables audio
/// playback rather than crashing the app at startup.
Object? initAudioBackend({void Function()? init}) {
  try {
    (init ?? () => JustAudioMediaKit.ensureInitialized(linux: true, windows: true))();
    return null;
  } catch (e) {
    return e;
  }
}
