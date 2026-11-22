// Turning a voice clip into text on this device (docs/superpowers/specs/2026-11-22-voice-transcripts-design.md).
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'model.dart';
import 'sherpa_transcriber.dart';

class TranscriptResult {
  const TranscriptResult(this.text, this.lang);

  /// Trimmed; empty when the clip had no speech.
  final String text;

  /// Whisper's detected language code, when it gave one.
  final String? lang;
}

abstract class Transcriber {
  Future<TranscriptResult> transcribe(String m4aPath, ModelPaths paths);
}

/// Runs [inner]'s jobs one at a time, in order, so two copies of the model never load at once.
class SerialTranscriber implements Transcriber {
  SerialTranscriber(this.inner);
  final Transcriber inner;
  Future<void> _tail = Future.value();

  @override
  Future<TranscriptResult> transcribe(String m4aPath, ModelPaths paths) {
    final job = _tail.then((_) => inner.transcribe(m4aPath, paths));
    _tail = job.then<void>((_) {}, onError: (_) {});
    return job;
  }
}

class _Unavailable implements Transcriber {
  const _Unavailable();
  @override
  Future<TranscriptResult> transcribe(String m4aPath, ModelPaths paths) =>
      Future.error(UnsupportedError('no transcripts on the web'));
}

final transcriberProvider = Provider<Transcriber>(
    (ref) => kIsWeb ? const _Unavailable() : SerialTranscriber(const SherpaTranscriber()));
