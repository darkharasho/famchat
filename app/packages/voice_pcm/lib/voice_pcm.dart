// Decoding voice clips to PCM through the platform's own decoder (AVFoundation, MediaCodec).
import 'dart:typed_data';

import 'package:flutter/services.dart';

const _channel = MethodChannel('voice_pcm');

/// [path]'s audio as mono float samples, and their rate (16000 on iOS and macOS; the clip's own
/// rate on Android). Throws [PlatformException] when the file can't be decoded.
Future<(Float32List, int)> decodeVoicePcm(String path) async {
  final r = await _channel.invokeMapMethod<String, Object?>('decode', {'path': path});
  final samples = r?['samples'], rate = r?['sampleRate'];
  if (samples is! Float32List || rate is! int) {
    throw PlatformException(code: 'bad_result', message: 'voice_pcm returned no samples');
  }
  return (samples, rate);
}
