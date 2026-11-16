// Riverpod wiring for voice: recorder and player factories (tests swap in fakes), whether this
// platform can record AAC, and the app-wide playback notifier.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../audio_init.dart';
import 'playback.dart';
import 'voice_player.dart';
import 'voice_recorder.dart';

final voiceRecorderFactoryProvider = Provider<VoiceRecorder Function()>((ref) => RecordVoiceRecorder.new);

final voicePlayerFactoryProvider = Provider<VoicePlayer Function()>((ref) => JustVoicePlayer.new);

/// Whether the record button shows: false where the recorder can't make AAC-LC (Chrome), or the check
/// fails or takes too long.
final voiceRecordingSupportedProvider = FutureProvider<bool>((ref) async {
  final rec = ref.watch(voiceRecorderFactoryProvider)();
  try {
    return await rec.supported().timeout(const Duration(seconds: 5));
  } catch (_) {
    return false;
  } finally {
    unawaited(disposeWithin(rec.dispose));
  }
});

final voicePlaybackProvider = NotifierProvider<VoicePlayback, PlaybackState>(VoicePlayback.new);
