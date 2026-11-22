// The per-device "Transcribe my voice messages" setting (off by default), stored locally with
// SharedPreferencesAsync like Close to tray. The model it needs is in lib/transcripts/model.dart.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const voiceTranscriptsPrefKey = 'voice_transcripts';

class VoiceTranscriptsNotifier extends AsyncNotifier<bool> {
  @override
  Future<bool> build() async => await SharedPreferencesAsync().getBool(voiceTranscriptsPrefKey) ?? false;

  Future<void> set(bool on) async {
    await SharedPreferencesAsync().setBool(voiceTranscriptsPrefKey, on);
    state = AsyncData(on);
  }
}

final voiceTranscriptsProvider = AsyncNotifierProvider<VoiceTranscriptsNotifier, bool>(VoiceTranscriptsNotifier.new);
