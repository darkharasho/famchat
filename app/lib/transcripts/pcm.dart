// Voice clips as raw samples for the transcriber: the platform decoder on iOS, macOS and Android
// (package voice_pcm), and the libmpv the app plays audio with on Linux and Windows.
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:voice_pcm/voice_pcm.dart';

import 'pcm_desktop.dart';

/// Mono samples in [-1, 1] at [sampleRate] Hz.
class Pcm {
  const Pcm(this.samples, this.sampleRate);
  final Float32List samples;
  final int sampleRate;
}

class PcmException implements Exception {
  const PcmException(this.message);
  final String message;
  @override
  String toString() => 'PcmException: $message';
}

/// [m4aPath]'s audio as mono samples: at 16000 Hz, except on Android (the clip's own rate).
Future<Pcm> decodeToPcm(String m4aPath) async {
  if (kIsWeb) throw const PcmException('not on the web');
  switch (defaultTargetPlatform) {
    case TargetPlatform.linux || TargetPlatform.windows:
      return Pcm(await decodeWithMpv(m4aPath), 16000);
    default:
      try {
        final (samples, rate) = await decodeVoicePcm(m4aPath);
        return Pcm(samples, rate);
      } on PlatformException catch (e) {
        throw PcmException(e.message ?? e.code);
      } on MissingPluginException {
        throw const PcmException('no decoder on this platform');
      }
  }
}
