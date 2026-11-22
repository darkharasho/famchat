// Where transcripts get made: after this user sends a voice message (when they turned it on), and
// when anyone taps Transcribe (lib/screens/chats). Audio and text stay on this device; only my own
// clips' transcripts are sent, inside the encrypted chat (docs/protocol.md "Transcripts").
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../chat/chat_sync.dart';
import '../chat/providers.dart';
import '../settings/voice_transcripts.dart';
import '../voice/waveform.dart';
import 'model.dart';
import 'transcriber.dart';

/// Clips longer than this aren't transcribed by themselves (Transcribe in the menu still works).
const autoTranscribeMax = Duration(minutes: 3);

class TranscriptsService {
  TranscriptsService({
    required this.sync,
    required this.transcriber,
    required this.model,
    required this.enabled,
    required this.tempDir,
  });

  final ChatSync sync;
  final Transcriber transcriber;

  /// The model's state, looked at afresh.
  final Future<ModelState> Function() model;

  /// Whether this user turned on "Transcribe my voice messages".
  final Future<bool> Function() enabled;
  final Future<Directory> Function() tempDir;

  /// Ids of the voice messages being transcribed now (their bubbles say so).
  final transcribing = ValueNotifier<Set<String>>(const {});
  int _seq = 0;

  /// Transcribes the clip just sent as [messageId] and sends the text, when transcripts are on, the
  /// model is ready, the clip isn't scheduled and it's at most [autoTranscribeMax]. Never throws.
  Future<void> afterVoiceSent(String chatId, String messageId, RecordedVoice v, {required bool scheduled}) async {
    try {
      if (scheduled || v.duration > autoTranscribeMax) return;
      if (!await enabled()) return;
      final m = await model();
      if (m is! ModelReady) return;
      final r = await _transcribe(messageId, v.bytes, m.paths);
      await sync.sendTranscript(chatId, messageId, r.text, lang: r.lang);
    } catch (e) {
      debugPrint('voice transcript failed: $e');
    }
  }

  Future<TranscriptResult> _transcribe(String messageId, Uint8List clip, ModelPaths paths) async {
    transcribing.value = {...transcribing.value, messageId};
    final dir = Directory(p.join((await tempDir()).path, 'voice-transcribe'));
    final file = File(p.join(dir.path, '${DateTime.now().microsecondsSinceEpoch}-${_seq++}.m4a'));
    try {
      await dir.create(recursive: true);
      await file.writeAsBytes(clip, flush: true);
      return await transcriber.transcribe(file.path, paths);
    } finally {
      transcribing.value = {...transcribing.value}..remove(messageId);
      if (await file.exists()) await file.delete();
    }
  }

  void dispose() => transcribing.dispose();
}

final transcriptsServiceProvider = Provider<TranscriptsService?>((ref) {
  final sync = ref.watch(chatSyncProvider);
  if (sync == null || kIsWeb) return null;
  final s = TranscriptsService(
    sync: sync,
    transcriber: ref.watch(transcriberProvider),
    model: () async {
      await ref.read(transcriptModelProvider.notifier).refresh();
      return ref.read(transcriptModelProvider);
    },
    enabled: () => ref.read(voiceTranscriptsProvider.future),
    tempDir: getTemporaryDirectory,
  );
  ref.onDispose(s.dispose);
  return s;
});
