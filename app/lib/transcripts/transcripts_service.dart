// Where transcripts get made: after this user sends a voice message (when they turned it on), and
// when anyone taps Transcribe (lib/screens/chats). Audio and text stay on this device; only my own
// clips' transcripts are sent, inside the encrypted chat (docs/protocol.md "Transcripts").
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../chat/chat_sync.dart';
import '../chat/db/chat_db.dart';
import '../chat/message_changes.dart';
import '../chat/plaintext.dart';
import '../chat/providers.dart';
import '../media/media_service.dart';
import '../media/providers.dart';
import '../settings/voice_transcripts.dart';
import '../voice/waveform.dart';
import 'model.dart';
import 'transcriber.dart';

/// How a Transcribe from the menu ended.
enum TranscribeOutcome { done, noSpeech, gone, failed }

/// Clips longer than this aren't transcribed by themselves (Transcribe in the menu still works).
const autoTranscribeMax = Duration(minutes: 3);

class TranscriptsService {
  TranscriptsService({
    required this.sync,
    required this.transcriber,
    required this.model,
    required this.enabled,
    required this.tempDir,
    this.loadClip,
  });

  final ChatSync sync;
  final Transcriber transcriber;

  /// The model's state, looked at afresh.
  final Future<ModelState> Function() model;

  /// Whether this user turned on "Transcribe my voice messages".
  final Future<bool> Function() enabled;
  final Future<Directory> Function() tempDir;

  /// A voice message's clip (from the cache or the server), for Transcribe; null when it's gone.
  final Future<Uint8List?> Function(VoiceBody)? loadClip;

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

  /// Transcribes voice message [m] now (Transcribe in the menu; the caller makes sure the model is
  /// downloaded). My own clip's transcript is sent to the chat, as the sender's; anyone else's is
  /// kept on this device only.
  Future<TranscribeOutcome> transcribeMessage(MessageRow m) async {
    if (m.kind != 'voice' || m.body == null || transcribing.value.contains(m.id)) return TranscribeOutcome.failed;
    try {
      final model = await this.model();
      if (model is! ModelReady) return TranscribeOutcome.failed;
      final body = Plaintext.decode(utf8.encode(m.body!));
      if (body is! VoiceBody) return TranscribeOutcome.failed;
      final clip = await loadClip?.call(body);
      if (clip == null) return TranscribeOutcome.gone;
      final r = await _transcribe(m.id, clip, model.paths);
      final text = r.text.trim();
      if (text.isEmpty) return TranscribeOutcome.noSpeech;
      // It may have been deleted (or disappeared) meanwhile.
      final now = await sync.db.messageById(m.id);
      if (now == null || messageChanges([now, ...await sync.db.changesTo(m.chatId, m.id)]).isDeleted(m.id)) {
        return TranscribeOutcome.gone;
      }
      if (m.senderUserId == sync.me.userId) {
        return await sync.sendTranscript(m.chatId, m.id, text, lang: r.lang) == null ? TranscribeOutcome.gone : TranscribeOutcome.done;
      }
      var local = text;
      if (local.length > maxTranscriptLength) local = local.substring(0, maxTranscriptLength);
      await sync.db.putLocalTranscript(m.chatId, m.id, local);
      return TranscribeOutcome.done;
    } catch (e) {
      debugPrint('transcribe failed: $e');
      return TranscribeOutcome.failed;
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
    loadClip: (v) async => ref.read(mediaServiceProvider)?.load(v.ref),
  );
  ref.onDispose(s.dispose);
  return s;
});

/// Ids of the voice messages being transcribed on this device now.
final transcribingProvider = StreamProvider<Set<String>>((ref) {
  final s = ref.watch(transcriptsServiceProvider);
  if (s == null) return Stream.value(const {});
  final c = StreamController<Set<String>>();
  void push() => c.add(s.transcribing.value);
  s.transcribing.addListener(push);
  push();
  ref.onDispose(() {
    s.transcribing.removeListener(push);
    c.close();
  });
  return c.stream;
});

/// Transcripts made on this device in a chat: message id → text.
final localTranscriptsProvider = StreamProvider.family<Map<String, String>, String>(
    (ref, chatId) => ref.watch(chatDbProvider).watchLocalTranscripts(chatId));
