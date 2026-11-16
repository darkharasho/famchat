// Capturing a voice clip: an interface the recording controller uses, and its `record` implementation.
import 'dart:typed_data';

import 'package:record/record.dart';

import 'voice_io.dart';
import 'waveform.dart';

/// The voice format (spec "Voice messages"; spike settings): AAC-LC `.m4a`, 48 kbps, mono, 44.1 kHz.
const voiceRecordConfig = RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 48000, numChannels: 1, sampleRate: 44100);

/// One recording session's microphone. Used once: start, then stop or cancel, then dispose.
abstract interface class VoiceRecorder {
  /// Whether this platform records AAC-LC (false in Chrome).
  Future<bool> supported();

  /// Asks for the microphone if needed; false when denied.
  Future<bool> permission();

  Future<void> start();

  /// Input level 0..1 every [levelInterval] while recording.
  Stream<double> levels();

  /// Stops and returns the `.m4a` bytes (null if the platform produced nothing).
  Future<Uint8List?> stop();

  /// Stops and throws the recording away.
  Future<void> cancel();

  Future<void> dispose();
}

class RecordVoiceRecorder implements VoiceRecorder {
  final _rec = AudioRecorder();

  @override
  Future<bool> supported() => _rec.isEncoderSupported(voiceRecordConfig.encoder);

  @override
  Future<bool> permission() => _rec.hasPermission();

  @override
  Future<void> start() async => _rec.start(voiceRecordConfig, path: await newRecordingPath());

  @override
  Stream<double> levels() => _rec.onAmplitudeChanged(levelInterval).map((a) => levelFromDb(a.current));

  @override
  Future<Uint8List?> stop() async {
    final out = await _rec.stop();
    return out == null || out.isEmpty ? null : takeRecording(out);
  }

  @override
  Future<void> cancel() => _rec.cancel();

  @override
  Future<void> dispose() => _rec.dispose();
}
